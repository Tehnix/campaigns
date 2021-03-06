module Job.Dispatch
  ( dispatchJob
  ) where

import Import

import Job.Activation
import Job.StepAchieved
import Job.Tracking
import Job.Welcome

-- | Dispatch jobs to their repsective handlers.
dispatchJob :: Entity Job -> HandlerT App IO ()
dispatchJob (Entity jobId job) = do
  master <- getYesod
  -- Update the job attempt.
  runDB $ update jobId [JobAttempt +=. 1]
  -- Dispatch the action to the correct handler.
  case jobAction job of
    SendActiviatonMail   -> sendActivationMail jobId $ jobValue job
    SendWelcomeMail      -> sendWelcomeMail jobId $ jobValue job
    SendStepAchievedMail -> sendStepAchievedMail jobId $ jobValue job
  -- | Send tracking if Google Analytics is enabled.
  case appAnalytics $ appSettings master of
    Nothing     -> return ()
    Just uaCode -> sendGoogleAnalyticsTracking uaCode (jobAction job) (jobValue job)
