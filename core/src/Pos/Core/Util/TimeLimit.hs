{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Pos.Core.Util.TimeLimit
       (
         -- * Log warning when action takes too much time
         CanLogInParallel
       , WaitingDelta (..)
       , logWarningLongAction
       , logWarningWaitOnce
       , logWarningWaitLinear
       , logWarningSWaitLinear
       , logWarningWaitInf

         -- * Random invervals
       , runWithRandomIntervals
       ) where

import           Universum

import           Data.Time.Units (Microsecond, Second, convertUnit)
import           Formatting (sformat, shown, stext, (%))
import           UnliftIO (MonadUnliftIO)

import           Pos.Core.Conc (delay, withAsyncWithUnmask)
import           Pos.Crypto.Random (randomNumber)
import           Pos.Util.Log (LoggingHandler, WithLogger, logWarning)
import           Pos.Util.Log.LogSafe (logWarningS)

-- | Data type to represent waiting strategy for printing warnings
-- if action take too much time.
--
-- [LW-4]: this probably will be moved somewhere from here
data WaitingDelta
    = WaitOnce      Second              -- ^ wait s seconds and stop execution
    | WaitLinear    Second              -- ^ wait s, s * 2, s * 3  , s * 4  , ...      seconds
    | WaitGeometric Microsecond Double  -- ^ wait m, m * q, m * q^2, m * q^3, ... microseconds
    deriving (Show)

-- | Constraint for something that can be logged in parallel with other action.
type CanLogInParallel m =
    (MonadMask m, WithLogger m, MonadIO m, MonadUnliftIO m)


-- | Run action and print warning if it takes more time than expected.
logWarningLongAction
    :: forall m a.
       CanLogInParallel m
    => LoggingHandler -> Bool -> WaitingDelta -> Text -> m a -> m a
logWarningLongAction lh secure delta actionTag action =
    -- Previous implementation was
    --
    --   bracket (fork $ waitAndWarn delta) killThread (const action)
    --
    -- but this has a subtle problem: 'killThread' can be interrupted even
    -- when exceptions are masked, so it's possible that the forked thread is
    -- left running, polluting the logs with misinformation.
    --
    -- 'withAsync' is assumed to take care of this, and indeed it does for
    -- 'Production's implementation, which uses the definition from the async
    -- package: 'uninterruptibleCancel' is used to kill the thread.
    --
    -- thinking even more about it, unmasking auxilary thread is crucial if
    -- this function is going to be called under 'mask'.
    withAsyncWithUnmask (\unmask -> unmask $ waitAndWarn delta) (const action)
  where
    logFunc :: Text -> m ()
    logFunc = bool logWarning (logWarningS lh) secure
    --TODO check if LoggingHandler or the necessaey elems can be acquired from the logging monad
    printWarning t = logFunc $ sformat ("Action `"%stext%"` took more than "%shown)
                                       actionTag t

    -- [LW-4]: avoid code duplication somehow (during refactoring)
    waitAndWarn (WaitOnce      s  ) = delay s >> printWarning s
    waitAndWarn (WaitLinear    s  ) =
        let waitLoop acc = do
                delay s
                printWarning acc
                waitLoop (acc + s)
        in waitLoop s
    waitAndWarn (WaitGeometric s q) =
        let waitLoop acc t = do
                delay t
                let newAcc = acc + t
                let newT   = round $ fromIntegral t * q
                printWarning (convertUnit newAcc :: Second)
                waitLoop newAcc newT
        in waitLoop 0 s

{- Helper functions to avoid dealing with data type -}

-- | Specialization of 'logWarningLongAction' with 'WaitOnce'.
logWarningWaitOnce :: CanLogInParallel m => LoggingHandler -> Second -> Text -> m a -> m a
logWarningWaitOnce lh = logWarningLongAction lh False . WaitOnce

-- | Specialization of 'logWarningLongAction' with 'WaiLinear'.
logWarningWaitLinear :: CanLogInParallel m => LoggingHandler -> Second -> Text -> m a -> m a
logWarningWaitLinear lh = logWarningLongAction lh False . WaitLinear

-- | Secure version of 'logWarningWaitLinear'.
logWarningSWaitLinear :: CanLogInParallel m => LoggingHandler -> Second -> Text -> m a -> m a
logWarningSWaitLinear lh = logWarningLongAction lh True . WaitLinear

-- | Specialization of 'logWarningLongAction' with 'WaitGeometric'
-- with parameter @1.3@. Accepts 'Second'.
logWarningWaitInf :: CanLogInParallel m => LoggingHandler -> Second -> Text -> m a -> m a
logWarningWaitInf lh = logWarningLongAction lh False . (`WaitGeometric` 1.3) . convertUnit

-- | Wait random number of 'Microsecond'`s between min and max.
waitRandomInterval
    :: MonadIO m
    => Microsecond -> Microsecond -> m ()
waitRandomInterval minT maxT = do
    interval <-
        (+ minT) . fromIntegral <$>
        liftIO (randomNumber $ fromIntegral $ maxT - minT)
    delay interval

-- | Wait random interval and then perform given action.
runWithRandomIntervals
    :: MonadIO m
    => Microsecond -> Microsecond -> m () -> m ()
runWithRandomIntervals minT maxT action = do
  waitRandomInterval minT maxT
  action
  runWithRandomIntervals minT maxT action
