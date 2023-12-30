{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeOperators         #-}


module Servant.PureScript.Internal where

import           Control.Lens

import           Data.Bifunctor
import           Data.Char
import           Data.Monoid
import           Data.Proxy
import           Data.Set                           (Set)
import qualified Data.Set                           as Set
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import           Data.Typeable

import           Language.PureScript.Bridge
import           Language.PureScript.Bridge.PSTypes


import           Servant.Foreign
import           Servant.Foreign.Internal


-- | Our language type is Paramized, so you can choose a custom 'TypeBridge' for your translation, by
--   providing your own data type and implementing 'HasBridge' for it.
--
-- > data MyBridge
-- >
-- > myBridge :: TypeBridge
-- > myBridge = defaultBridge <|> customBridge1 <|> customBridge2
-- >
-- > instance HasBridge MyBridge where
-- >   languageBridge _ = myBridge
--
data PureScript bridgeSelector

instance (Typeable a, HasBridge bridgeSelector) => HasForeignType (PureScript bridgeSelector) PSType a where
  typeFor _ _ _ = languageBridge (Proxy :: Proxy bridgeSelector) (mkTypeInfo (Proxy :: Proxy a))

class HasBridge a where
  languageBridge :: Proxy a -> FullBridge

-- | Use 'PureScript' 'DefaultBridge' if 'defaultBridge' suffices for your needs.
data DefaultBridge

-- | 'languageBridge' for 'DefaultBridge' evaluates to 'buildBridge' 'defaultBridge' - no surprise there.
instance HasBridge DefaultBridge where
  languageBridge _ = buildBridge defaultBridge

-- | A proxy for 'DefaultBridge'
defaultBridgeProxy :: Proxy DefaultBridge
defaultBridgeProxy = Proxy

type ParamName = Text

data Param f = Param {
  _pName :: ParamName
, _pType :: f
} deriving (Eq, Ord, Show)

type PSParam = Param PSType

makeLenses ''Param


data Settings = Settings {
  _apiModuleName         :: Text
  -- | This function parameters should instead be put in a Reader monad.
  --
  --   'baseUrl' will be put there by default, you can add additional parameters.
  --
  --   If your API uses a given parameter name multiple times with different types,
  --   only the ones matching the type of the first occurrence
  --   will be put in the Reader monad, all others will still be passed as function parameter.
, _readerParams          :: Set ParamName
, _standardImports       :: ImportLines
  -- | If you want codegen for servant-subscriber, set this to True. See the central-counter example
  --   for a simple usage case.
, _generateSubscriberAPI :: Bool
}
makeLenses ''Settings

defaultSettings :: Settings
defaultSettings = Settings {
    _apiModuleName    = "ServerAPI"
  , _readerParams     = Set.singleton baseURLId
  , _standardImports = importsFromList
        [ ImportLine "Control.Monad.Reader.Class" Nothing (Set.fromList [ "class MonadAsk", "ask" ])
        , ImportLine "Control.Monad.Error.Class" Nothing (Set.fromList [ "class MonadError" ])
        , ImportLine "Control.Monad.Aff.Class" Nothing (Set.fromList [ "class MonadAff" ])
        , ImportLine "Network.HTTP.Affjax" Nothing (Set.fromList [ "AJAX" ])
        , ImportLine "Data.Nullable" Nothing (Set.fromList [ "toNullable" ])
        , ImportLine "Servant.PureScript.Affjax" Nothing (Set.fromList [ "AjaxError", "defaultRequest", "affjax" ])
        , ImportLine "Servant.PureScript.Settings" Nothing (Set.fromList [ "SPSettings_(..)", "SPSettingsDecodeJson_(..)", "SPSettingsEncodeJson_(..)", "gDefaultToURLPiece" ])
        , ImportLine "Servant.PureScript.Util" Nothing (Set.fromList [ "encodeListQuery", "encodeURLPiece", "encodeQueryItem", "getResult", "encodeHeader" ])
        , ImportLine "Prim" Nothing (Set.fromList [ "String" ]) -- For baseURL!
        , ImportLine "Data.Maybe" Nothing (Set.fromList [ "Maybe(..)"])
        , ImportLine "Data.String" Nothing (Set.fromList ["joinWith"])
        , ImportLine "Data.Array" Nothing (Set.fromList ["catMaybes", "null"])
        , ImportLine "Data.Argonaut.Core" Nothing (Set.fromList [ "stringify" ])
        ]
  , _generateSubscriberAPI = False
  }

-- | Add a parameter name to be us put in the Reader monad instead of being passed to the
--   generated functions.
addReaderParam :: ParamName -> Settings -> Settings
addReaderParam n opts = opts & over readerParams (Set.insert n)

baseURLId :: ParamName
baseURLId = "baseURL"

baseURLParam :: PSParam
baseURLParam = Param baseURLId psString

subscriberToUserId :: ParamName
subscriberToUserId = "spToUser_"

makeTypedToUserParam :: PSType -> PSParam
makeTypedToUserParam response = Param subscriberToUserId (psTypedToUser response)

apiToList :: forall bridgeSelector api.
  ( HasForeign (PureScript bridgeSelector) PSType api
  , GenerateList PSType (Foreign PSType api)
  , HasBridge bridgeSelector
  ) => Proxy api -> Proxy bridgeSelector -> [Req PSType]
apiToList _ _ = listFromAPI (Proxy :: Proxy (PureScript bridgeSelector)) (Proxy :: Proxy PSType) (Proxy :: Proxy api)


-- | Transform a given identifer to be a valid PureScript variable name (hopefully).
toPSVarName :: Text -> Text
toPSVarName = dropInvalid . unTitle . doPrefix . replaceInvalid
  where
    unTitle = uncurry mappend . first T.toLower . T.splitAt 1
    doPrefix t = let
        s = T.head t
        cond = isAlpha s || s == '_'
      in
        if cond then t else "_" <> t
    replaceInvalid  = T.replace "-" "_"
    dropInvalid = let
        isValid c = isAlphaNum c || c == '_'
      in
        T.filter isValid

psTypedToUser :: PSType -> PSType
psTypedToUser response = TypeInfo {
  _typePackage = "purescript-subscriber"
  , _typeModule = "Servant.Subscriber.Util"
  , _typeName = "TypedToUser"
  , _typeParameters = [response, psTypeParameterA]
  }

psSubscriptions :: PSType
psSubscriptions = TypeInfo {
    _typePackage = "purescript-subscriber"
  , _typeModule = "Servant.Subscriber.Subscriptions"
  , _typeName = "Subscriptions"
  , _typeParameters = [psTypeParameterA]
  }

psTypeParameterA :: PSType
psTypeParameterA = TypeInfo {
    _typePackage = ""
  , _typeModule = ""
  , _typeName = "a"
  , _typeParameters = []
  }

-- use servant-foreign's camelCaseL legacy version
jsCamelCaseL :: Getter FunctionName Text
jsCamelCaseL = _FunctionName . to (convert . map (T.replace "-" ""))
  where
    convert []     = ""
    convert (p:ps) = mconcat $ p : map capitalize ps
    capitalize ""   = ""
    capitalize name = toUpper (T.head name) `T.cons` T.tail name
