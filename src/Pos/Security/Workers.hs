{-# LANGUAGE ScopedTypeVariables #-}

module Pos.Security.Workers
       ( SecurityWorkersClass (..)
       ) where

import           Universum

import           Control.Concurrent.STM     (TVar, newTVar, readTVar, writeTVar)
import qualified Data.HashMap.Strict        as HM
import           Data.Tagged                (Tagged (..))
import           Data.Time.Units            (Millisecond, convertUnit)
import           Formatting                 (build, int, sformat, (%))
import           Mockable                   (delay)
import           Serokell.Util              (sec)
import           System.Wlog                (logWarning)

import           Pos.Binary.Ssc             ()
import           Pos.Block.Core             (Block, BlockHeader, MainBlock,
                                             mainBlockSscPayload)
import           Pos.Block.Logic            (needRecovery)
import           Pos.Block.Network          (requestTipOuts, triggerRecovery)
import           Pos.Communication.Protocol (OutSpecs, SendActions (..), WorkerSpec,
                                             localWorker, worker)
import           Pos.Constants              (blkSecurityParam, genesisHash,
                                             mdNoBlocksSlotThreshold,
                                             mdNoCommitmentsEpochThreshold)
import           Pos.Context                (getOurPublicKey, getOurStakeholderId,
                                             getUptime, recoveryCommGuard)
import           Pos.Core                   (EpochIndex, SlotId (..), epochIndexL,
                                             flattenEpochOrSlot, flattenSlotId,
                                             headerHash, headerLeaderKeyL, prevBlockL)
import           Pos.Crypto                 (PublicKey)
import           Pos.DB                     (DBError (DBMalformed))
import           Pos.DB.Block               (MonadBlockDB, blkGetHeader)
import           Pos.DB.DB                  (getTipHeader, loadBlundsFromTipByDepth)
import           Pos.Reporting.Methods      (reportMisbehaviourSilent, reportingFatal)
import           Pos.Security.Class         (SecurityWorkersClass (..))
import           Pos.Shutdown               (runIfNotShutdown)
import           Pos.Slotting               (getCurrentSlot, getLastKnownSlotDuration,
                                             onNewSlot)
import           Pos.Ssc.Class              (SscWorkersClass)
import           Pos.Ssc.GodTossing         (GtPayload (..), SscGodTossing,
                                             getCommitmentsMap)
import           Pos.Ssc.NistBeacon         (SscNistBeacon)
import           Pos.Util                   (mconcatPair)
import           Pos.Util.Chrono            (NewestFirst (..))
import           Pos.WorkMode.Class         (WorkMode)


instance SecurityWorkersClass SscGodTossing where
    securityWorkers =
        Tagged $
        merge [ checkForReceivedBlocksWorker
              , checkForIgnoredCommitmentsWorker
              ]
      where
        merge = mconcatPair . map (first pure)

instance SecurityWorkersClass SscNistBeacon where
    securityWorkers = Tagged $ first pure checkForReceivedBlocksWorker

checkForReceivedBlocksWorker ::
    (SscWorkersClass ssc, WorkMode ssc ctx m)
    => (WorkerSpec m, OutSpecs)
checkForReceivedBlocksWorker =
    worker requestTipOuts checkForReceivedBlocksWorkerImpl

checkEclipsed
    :: (MonadBlockDB ssc m)
    => PublicKey -> SlotId -> BlockHeader ssc -> m Bool
checkEclipsed ourPk slotId x = notEclipsed x
  where
    onBlockLoadFailure header = do
        throwM $ DBMalformed $
            sformat ("Eclipse check: didn't manage to find parent of "%build%
                     " with hash "%build%", which is not genesis")
                    (headerHash header)
                    (header ^. prevBlockL)
    -- We stop looking for blocks when we've gone earlier than
    -- 'mdNoBlocksSlotThreshold':
    pastThreshold header =
        (flattenSlotId slotId - flattenEpochOrSlot header) >
        mdNoBlocksSlotThreshold
    -- Run the iteration starting from tip block; if we have found
    -- that we're eclipsed, we report it and ask neighbors for
    -- headers. If there are no main blocks generated by someone else
    -- in the past 'mdNoBlocksSlotThreshold' slots, it's bad and we've
    -- been eclipsed.  Here's how we determine that a block is good
    -- (i.e. main block generated not by us):
    isGoodBlock (Left _)   = False
    isGoodBlock (Right mb) = mb ^. headerLeaderKeyL /= ourPk
    -- Okay, now let's iterate until we see a good blocks or until we
    -- go past the threshold and there's no point in looking anymore:
    notEclipsed header = do
        let prevBlock = header ^. prevBlockL
        if | pastThreshold header     -> pure False
           | prevBlock == genesisHash -> pure True
           | isGoodBlock header       -> pure True
           | otherwise                ->
                 blkGetHeader prevBlock >>= \case
                     Just h  -> notEclipsed h
                     Nothing -> onBlockLoadFailure header $> True

checkForReceivedBlocksWorkerImpl
    :: forall ssc ctx m.
       (SscWorkersClass ssc, WorkMode ssc ctx m)
    => SendActions m -> m ()
checkForReceivedBlocksWorkerImpl SendActions {..} = afterDelay $ do
    repeatOnInterval (const (sec' 4)) . reportingFatal . recoveryCommGuard $
        whenM (needRecovery @ssc) $ triggerRecovery enqueueMsg
    repeatOnInterval (min (sec' 20)) . reportingFatal . recoveryCommGuard $ do
        ourPk <- getOurPublicKey
        let onSlotDefault slotId = do
                header <- getTipHeader @ssc
                unlessM (checkEclipsed ourPk slotId header) onEclipsed
        whenJustM getCurrentSlot onSlotDefault
  where
    sec' :: Int -> Millisecond
    sec' = convertUnit . sec
    afterDelay action = delay (sec 3) >> action
    onEclipsed = do
        logWarning $
            "Our neighbors are likely trying to carry out an eclipse attack! " <>
            "There are no blocks younger " <>
            "than 'mdNoBlocksSlotThreshold' that we didn't generate " <>
            "by ourselves"
        reportEclipse
    repeatOnInterval delF action = runIfNotShutdown $ do
        () <- action
        getLastKnownSlotDuration >>= delay . delF
        repeatOnInterval delF action
    reportEclipse = do
        bootstrapMin <- (+ sec 10) . convertUnit <$> getLastKnownSlotDuration
        nonTrivialUptime <- (> bootstrapMin) <$> getUptime
        let reason =
                "Eclipse attack was discovered, mdNoBlocksSlotThreshold: " <>
                show (mdNoBlocksSlotThreshold :: Int)
        -- TODO [CSL-1340]: should it be critical or not? Is it
        -- misbehavior or error?
        when nonTrivialUptime $ recoveryCommGuard $
            reportMisbehaviourSilent True reason

checkForIgnoredCommitmentsWorker
    :: forall ctx m.
       WorkMode SscGodTossing ctx m
    => (WorkerSpec m, OutSpecs)
checkForIgnoredCommitmentsWorker = localWorker $ do
    epochIdx <- atomically (newTVar 0)
    void $ onNewSlot True (checkForIgnoredCommitmentsWorkerImpl epochIdx)

checkForIgnoredCommitmentsWorkerImpl
    :: forall ctx m. (WorkMode SscGodTossing ctx m)
    => TVar EpochIndex -> SlotId -> m ()
checkForIgnoredCommitmentsWorkerImpl tvar slotId = recoveryCommGuard $ do
    -- Check prev blocks
    (kBlocks :: NewestFirst [] (Block SscGodTossing)) <-
        map fst <$> loadBlundsFromTipByDepth @SscGodTossing blkSecurityParam
    for_ kBlocks $ \blk -> whenRight blk checkCommitmentsInBlock

    -- Print warning
    lastCommitment <- atomically $ readTVar tvar
    when (siEpoch slotId - lastCommitment > mdNoCommitmentsEpochThreshold) $
        logWarning $ sformat
            ("Our neighbors are likely trying to carry out an eclipse attack! "%
             "Last commitment was at epoch "%int%", "%
             "which is more than 'mdNoCommitmentsEpochThreshold' epochs ago")
            lastCommitment
  where
    checkCommitmentsInBlock :: MainBlock SscGodTossing -> m ()
    checkCommitmentsInBlock block = do
        ourId <- getOurStakeholderId
        let commitmentInBlockchain = isCommitmentInPayload ourId (block ^. mainBlockSscPayload)
        when commitmentInBlockchain $
            atomically $ writeTVar tvar $ block ^. epochIndexL
    isCommitmentInPayload addr (CommitmentsPayload commitments _) =
        HM.member addr $ getCommitmentsMap commitments
    isCommitmentInPayload _ _ = False
