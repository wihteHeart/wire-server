{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}

module Spar.Data where

import Cassandra
import Control.Lens ((<&>))
import Control.Monad.Identity
import Data.String.Conversions
import Data.Time
import GHC.Stack

import qualified Data.Id as Brig
import qualified Data.UUID as UUID
import qualified SAML2.WebSSO as SAML


-- TODO: do we want to have a configurable upper limit for TTL?  (this check would have to throw errors.)


----------------------------------------------------------------------
-- saml state handling

storeRequest :: (HasCallStack, MonadClient m) => SAML.ID SAML.AuthnRequest -> SAML.Time -> m ()
storeRequest (SAML.ID rid) (SAML.Time endoflife) =
    retry x5 . write ins $ params Quorum (rid, endoflife, endoflife)
  where
    ins :: PrepQuery W (ST, UTCTime, UTCTime) ()
    ins = "INSERT INTO authreq (req, end_of_life) VALUES (?, ?) USING TTL = ?"  -- TODO: do this also below.  figure out how it works properly.

checkAgainstRequest :: (HasCallStack, MonadClient m) => UTCTime -> SAML.ID SAML.AuthnRequest -> m Bool
checkAgainstRequest now (SAML.ID rid) = do
    (retry x1 . query1 sel . params Quorum $ Identity rid) <&> \case
        Just (Identity (Just endoflife)) -> endoflife >= now
        _ -> False
  where
    sel :: PrepQuery R (Identity ST) (Identity (Maybe UTCTime))
    sel = "SELECT end_of_life FROM authreq WHERE req = ?"

storeAssertion :: (HasCallStack, MonadClient m) => UTCTime -> SAML.ID SAML.Assertion -> SAML.Time -> m Bool
storeAssertion now (SAML.ID aid) (SAML.Time endoflifeNew) = do
    notAReplay :: Bool <- (retry x1 . query1 sel . params Quorum $ Identity aid) <&> \case
        Just (Identity (Just endoflifeOld)) -> endoflifeOld < now
        _ -> False
    when notAReplay $ do
        retry x5 . write ins $ params Quorum (aid, endoflifeNew)
    pure notAReplay
  where
    sel :: PrepQuery R (Identity ST) (Identity (Maybe UTCTime))
    sel = "SELECT end_of_life FROM authresp WHERE resp = ?"

    ins :: PrepQuery W (ST, UTCTime) ()
    ins = "INSERT INTO authresp (resp, end_of_life) VALUES (?, ?)"


----------------------------------------------------------------------
-- user

-- | Add new user.  If user with this 'SAML.UserId' exists, overwrite it.
insertUser :: (HasCallStack, MonadClient m) => SAML.UserId -> Brig.UserId -> m ()
insertUser (SAML.UserId tenant subject) uid = retry x5 . write ins $ params Quorum (tenant', subject', uid')
  where
    tenant', subject', uid' :: ST
    tenant'  = cs $ SAML.encodeElem tenant
    subject' = cs $ SAML.encodeElem subject
    uid'     = Brig.idToText uid

    ins :: PrepQuery W (ST, ST, ST) ()
    ins = "INSERT INTO user (idp, sso_id, uid) VALUES (?, ?, ?)"

getUser :: (HasCallStack, MonadClient m) => SAML.UserId -> m (Maybe Brig.UserId)
getUser (SAML.UserId tenant subject) = (retry x1 . query1 sel $ params Quorum (tenant', subject')) <&> \case
  Just (Identity (Just (UUID.fromText -> Just uuid))) -> Just $ Brig.Id uuid
  _ -> Nothing
  where
    tenant', subject' :: ST
    tenant'  = cs $ SAML.encodeElem tenant
    subject' = cs $ SAML.encodeElem subject

    sel :: PrepQuery R (ST, ST) (Identity (Maybe ST))
    sel = "SELECT uid FROM authresp WHERE idp = ? AND sso_id = ?"

-- | Delete a user.  If no such user exists, do nothing.
deleteUser :: (HasCallStack, MonadClient m) => SAML.UserId -> m ()
deleteUser = undefined


----------------------------------------------------------------------
-- idp

-- NOTE TO FUTURE SELF: when storing IdPs, we need to handle tenant conflicts.  we need to rely on
-- the fact that the tenant in the 'SAML.UserId' is always unique.
