module Handler.SignupForm where
import           Import

import           Data.Char         (chr, ord)
import qualified Data.Text         as T
import qualified Network.HTTP.Base as HTTP (urlEncode)
import qualified Prelude           as P (head)
import           System.Random

data SignupForm = SignupForm
  { signupFormEmail    :: Text
  , signupFormLanguage :: Language
  , signupFormReferrer :: Maybe Text
  } deriving Show

-- | Handle the form submission from the signup page and redirect accordingly.
postSignupR :: Handler Html
postSignupR = do
  master <- getYesod
  messageRender <- getMessageRender
  ((result, _), _) <- runFormPost $ signupForm master defaultLanguage messageRender Nothing
  case result of
    FormSuccess res -> do
      -- Check if the mail already exists in the system.
      let mail = T.toLower $ signupFormEmail res
      maybeCheckMail <- runDB . getBy $ UniqueEmail mail
      case maybeCheckMail of
        Just _  -> do
          setMessageI MsgFormAlreadySignedUp
          redirectUltDest SignupR
        Nothing -> do
          -- Only add the user if they don't already exist.
          referredBy <- maybeReferrer $ signupFormReferrer res
          referralToken <- generateToken 45
          dashboardToken <- generateToken 30
          activationToken <- generateToken 90
          now <- liftIO getCurrentTime
          let lang = signupFormLanguage res
          -- Insert the new user into the database, and schedule the activation
          -- mail to be sent out.
          _ <- runDB $ do
             _ <- insert $ Signup mail referredBy referralToken dashboardToken activationToken False lang now now
             insert $ Job SendActiviatonMail (JobValueUserMail mail) Nothing 0 False now now
          redirect $ ConfirmSignupIR lang
    FormMissing     -> do
      setMessageI MsgFormMissing
      redirectUltDest SignupR
    FormFailure msg   -> do
      setMessage $ toHtml $ P.head msg
      redirectUltDest SignupR
  where
    -- Extract the referrer ID from a referral token.
    maybeReferrer referrer = do
      case referrer of
        Nothing -> return Nothing
        Just ref -> do
          maybeRef <- runDB . getBy $ UniqueReferralToken ref
          case maybeRef of
            Nothing                    -> return Nothing
            Just (Entity referrerId _) -> return $ Just referrerId
    -- Helper functions to filter out unwanted characters.
    illegalChars = [':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`']
    replaceChar = fmap $ (\c -> if c `elem` illegalChars then chr (ord c - 8) else c)
    replaceSpace = filter (/= '"')
    -- Generate a random token, used for the activation key, dashboard token and
    -- referral token.
    generateToken l = do
      gen <- liftIO newStdGen
      let ns = randomRs ('1', 'y') gen
      let randomString = replaceSpace . replaceChar . show $ take l ns
      return . T.pack $ HTTP.urlEncode randomString

-- | Construct the mail signup form. The mail is required, along with the
-- language being passed in a hidden field. Only optional field is the referrer
-- which is set if the user has been referred.
signupForm :: App -> Language -> (AppMessage -> Text) -> Maybe Text -> Html -> MForm Handler (FormResult SignupForm, Widget)
signupForm master lang messageRender referrer = renderDivs $ SignupForm
  <$> areq signupEmailField (FieldSettings "" Nothing (Just "email-input") Nothing [("placeholder", messageRender MsgEmailPlaceholder)]) Nothing
  <*> areq hiddenField "" (Just lang)
  <*> case referrer of
    Nothing  -> aopt hiddenField "" Nothing
    Just ref -> aopt hiddenField "" $ Just (Just (toPathPiece ref))
  where
    disallowedDomains = cmpDisallowDomains . appCampaign $ appSettings master
    disallowedPatterns = cmpDisallowPatterns . appCampaign $ appSettings master
    -- Check if the string contains the pattern in the user part of the email
    containsChar :: Text -> Text -> Bool
    containsChar s mail = isInfixOf s $ T.takeWhile (\c -> c /= '@') mail
    -- Check if the email has a disallowed domain
    hasDomain :: Text -> Text -> Bool
    hasDomain domain mail = domain == (T.tail $ T.dropWhile (\c -> c /= '@') (T.toLower mail))
    -- Custom email validation
    signupEmailField = check validateEmail emailField
    validateEmail mail
      | any (\s -> containsChar s mail) disallowedPatterns = Left (messageRender MsgFormDisallowedPattern :: Text)
      | any (\s -> hasDomain s mail) disallowedDomains     = Left (messageRender MsgFormDisallowedDomain :: Text)
      | otherwise                                          = Right mail
