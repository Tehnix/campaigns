module Job.Activation
  ( sendActivationMail
  ) where

import           Import

import qualified Crypto.Hash                as CH
import qualified Data.ByteString.Lazy.Char8 as C
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import qualified Network.HTTP.Simple        as HTTP

data MailchimpActivate = MailchimpActivate Text Text deriving Show

instance ToJSON MailchimpActivate where
  toJSON (MailchimpActivate email activationLink) =
    object [ "email_address" .= email
           -- ^ Mailchimp user email address
           , "status"        .= ("subscribed" :: Text)
           -- ^ Mailchimp user status (i.e. subscribed, pending etc)
           , "merge_fields"  .= object
                  [ "MMERGE15" .= activationLink
                  -- ^ Activation link mailchimp merge field
                  , "MMERGE18" .= ("Ja" :: Text)
                  -- ^ Add the user to the "Signed Up" group
                  ]
           ]

hexMD5 :: Text -> String
hexMD5 s = show (CH.hash (T.encodeUtf8 s) :: CH.Digest CH.MD5)

-- | Add the user to mailchimp list
sendActivationMail :: Key Job -> JobValue -> HandlerT App IO ()
sendActivationMail jobId (JobValueUserMail mail) = do
  $logInfo $ "Running sendActivationMail job for " <> mail
  -- Get the mailchimp API settings
  master <- getYesod
  let maybeGoogleAnalytics = appAnalytics $ appSettings master
  let mailchimpApiUser = T.encodeUtf8 . mcApiUser . appMailchimp $ appSettings master
  let mailchimpApiKey = T.encodeUtf8 . mcApiKey . appMailchimp $ appSettings master
  let mailchimpApiLocation = mcApiLocation . appMailchimp $ appSettings master
  now <- liftIO getCurrentTime
  maybeUser <- runDB . getBy $ UniqueEmail mail
  case maybeUser of
    Nothing              -> return ()
    Just (Entity _ signup) -> do
      let lang = signupLanguage signup
      let mailchimpListId = case lang of
            Danish    -> mcListIdDanish . mcListId . appMailchimp $ appSettings master
            Swedish   -> mcListIdSwedish . mcListId . appMailchimp $ appSettings master
            Norwegian -> mcListIdNorwegian . mcListId . appMailchimp $ appSettings master
      let mailchimpApiEndpoint = T.unpack $ "http://" <> mailchimpApiLocation <> ".api.mailchimp.com/3.0/lists/" <> mailchimpListId <> "/members/"
      render <- getUrlRender
      -- Add analytics tracking to the URL if it is set
      let utms = case maybeGoogleAnalytics of
            Nothing -> ""
            Just _  -> "?utm_medium=email&utm_campaign=activation"
      let activationUrl = render (ActivateSignupIR lang (signupActivationToken signup)) <> utms
      let subscriber = MailchimpActivate mail activationUrl
      let postUrl = parseRequest_ $ "POST " <> mailchimpApiEndpoint
      let postRequest = HTTP.setRequestBasicAuth mailchimpApiUser mailchimpApiKey
                      . HTTP.setRequestIgnoreStatus
                      $ HTTP.setRequestBodyJSON subscriber postUrl
      postResponse <- liftIO $ HTTP.httpLBS postRequest
      let postResp = T.decodeUtf8 . C.toStrict $ HTTP.getResponseBody postResponse
      -- Check if the API call was successful or not
      case HTTP.getResponseStatusCode postResponse of
        -- Status code 200 indicates the user was successfully added
        200 -> runDB $ update jobId [JobFinished =. True, JobUpdated =. now, JobResult =. Just postResp]

        -- If we get a status code 400, the user already exists and we need to
        -- send a PATCH request instead to update their information
        400 -> do
          let mailHash = hexMD5 mail
          let patchUrl = parseRequest_ $ "PATCH " <> mailchimpApiEndpoint <> mailHash
          let patchRequest = HTTP.setRequestBasicAuth mailchimpApiUser mailchimpApiKey
                           . HTTP.setRequestIgnoreStatus
                           $ HTTP.setRequestBodyJSON subscriber patchUrl
          patchResponse <- liftIO $ HTTP.httpLBS patchRequest
          let patchResp = T.decodeUtf8 . C.toStrict $ HTTP.getResponseBody patchResponse
          -- Check if the API call was successful or not
          case HTTP.getResponseStatusCode patchResponse of
            200 -> runDB $ update jobId [JobFinished =. True, JobUpdated =. now, JobResult =. Just patchResp]
            _   -> runDB $ update jobId [JobUpdated =. now, JobResult =. Just patchResp]

        -- Any other status code and the job is marked as failed
        _   -> runDB $ update jobId [JobUpdated =. now, JobResult =. Just "Failed"]

      return ()
sendActivationMail _ _ = return ()
