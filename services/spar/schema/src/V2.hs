{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

module V2 (migration) where

import Cassandra.Schema
import Control.Monad (void)
import Text.RawString.QQ

migration :: Migration
migration = Migration 2 "Add extra idp keys set" $ do

    void $ schema' [r|
        ALTER TABLE idp ADD meta_public_key blob;
        ALTER TABLE idp ADD extra_public_keys list<blob>;
    |]
