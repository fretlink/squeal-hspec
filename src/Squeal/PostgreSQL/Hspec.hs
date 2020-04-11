{-|
Helpers for creating database tests with hspec and squeal, inspired by Jonathan Fischoff's
[hspec-pg-transact](http://hackage.haskell.org/package/hspec-pg-transact).

This uses @tmp-postgres@ to automatically and connect to a temporary instance of postgres on a random port.

Tests can be written with 'itDB' which is wrapper around 'it' that uses the passed in 'TestDB' to run a db transaction automatically for the test.

The libary also provides a few other functions for more fine grained control over running transactions in tests.
-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonoLocalBinds   #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TupleSections    #-}
{-# LANGUAGE TypeInType       #-}
{-# LANGUAGE TypeOperators    #-}
module Squeal.PostgreSQL.Hspec
where

import           Control.Exception
import           Control.Monad
import           Control.Monad.Base     (liftBase)
import           Data.ByteString        (ByteString)
import qualified Data.ByteString.Char8  as BSC
import qualified Database.Postgres.Temp as Temp
import           Generics.SOP           (K)
import           Squeal.PostgreSQL
import           Squeal.PostgreSQL.Pool
import           System.Environment     (lookupEnv)
import           Test.Hspec

data TestDB a = TestDB
  { tempDB           :: Maybe Temp.DB
  -- ^ Handle for temporary @postgres@ process
  , pool             :: Pool a
  -- ^ Pool of 50 connections to the temporary @postgres@
  , connectionString :: ByteString
  }

type Fixtures schema a = (Pool (K Connection schema) -> IO a)
type Actions schema a = PoolPQ schema IO a
type SquealContext schema = TestDB (K Connection schema)
type FixtureContext schema fix = (SquealContext schema, fix)

testDBEnv :: String
testDBEnv = "TEST_DB_CONNECTION_STRING"

getOrCreateConnectionString :: IO (ByteString, Maybe Temp.DB)
getOrCreateConnectionString = do
  hasConnectionString <- lookupEnv testDBEnv
  maybe createTempDB (pure . (, Nothing) . BSC.pack) hasConnectionString

createTempDB :: IO (ByteString, Maybe Temp.DB)
createTempDB = do
  tempDB <- either throwIO return =<< Temp.startAndLogToTmp []
  let connectionString = BSC.pack (Temp.connectionString tempDB)
  pure (connectionString, Just tempDB)

-- | Start a temporary @postgres@ process and create a pool of connections to it
setupDB
  :: Migratory p => AlignedList (Migration p) schema0 schema
  -> Fixtures schema fix
  -> IO (FixtureContext schema fix)
setupDB migration fixtures = do
  (connectionString, tempDB) <- getOrCreateConnectionString
  BSC.putStrLn connectionString
  let singleStripe = 1
      keepConnectionForOneHour = 3600
      poolSizeOfFifty = 50
  pool <- createConnectionPool
     connectionString
     singleStripe
     keepConnectionForOneHour
     poolSizeOfFifty
  withConnection connectionString (migrateUp migration)
  res <- fixtures pool
  pure (TestDB {..}, res)

-- | Drop all the connections and shutdown the @postgres@ process
teardownDB
  :: Migratory p => AlignedList (Migration p) schema0 schema
  -> TestDB a
  -> IO ()
teardownDB migration TestDB {..} = do
  withConnection connectionString (migrateDown migration)
  destroyAllResources pool
  maybe (pure ()) (void . Temp.stop) tempDB

-- | Run an 'IO' action with a connection from the pool
withPool :: TestDB (K Connection schema) -> Actions schema a -> IO a
withPool testDB = liftBase . flip runPoolPQ (pool testDB)

-- | Run an 'DB' transaction, using 'transactionally_'
withDB :: Actions schema a -> TestDB (K Connection schema) -> IO a
withDB action testDB =
  runPoolPQ (transactionally_ action) (pool testDB)

-- | Flipped version of 'withDB'
runDB :: TestDB (K Connection schema) -> Actions schema a -> IO a
runDB = flip withDB

withFixture :: (fix -> Actions schema a) -> FixtureContext schema fix -> IO a
withFixture action (db, fix) =
  runPoolPQ (transactionally_ $ action fix) (pool db)

withoutFixture :: Actions schema a -> FixtureContext schema fix -> IO a
withoutFixture action (db, _) =
  runPoolPQ (transactionally_ action) (pool db)

-- | Helper for writing tests. Wrapper around 'it' that uses the passed
--   in 'TestDB' to run a db transaction automatically for the test.
itDB :: String -> Actions schema a -> SpecWith (FixtureContext schema ())
itDB msg action = it msg $ void . withoutFixture action

-- | Helper for writing tests. Wrapper around 'it' that uses the passed
-- in 'TestDB' to run a db transaction automatically for the test,
-- plus the result of the fixtures.
itDBF :: String -> (fix -> Actions schema a) -> SpecWith (FixtureContext schema fix)
itDBF msg action = it msg $ void . withFixture action

itDBF_ :: String -> Actions schema a -> SpecWith (FixtureContext schema fix)
itDBF_ msg action = it msg $ void . withoutFixture action

-- | Wraps 'describe' with a
--
-- @
--   'beforeAll' ('setupDB' migrate)
-- @
--
-- hook for creating a db and a
--
-- @
--   'afterAll' 'teardownDB'
-- @
--
-- hook for stopping a db.
describeDB
  :: Migratory p => AlignedList (Migration p) schema0 schema
  -> Fixtures schema ()
  -> String
  -> SpecWith (FixtureContext schema ())
  -> Spec
describeDB migrate fixture str =
  beforeAll (setupDB migrate fixture) . afterAll (teardownDB migrate . fst) . describe str

-- | Like `decribeDB`, but allow fixtures to pass
-- | a result to all specs
describeFixtures
  :: Migratory p => AlignedList (Migration p) schema0 schema
  -> Fixtures schema fix
  -> String
  -> SpecWith (FixtureContext schema fix)
  -> Spec
describeFixtures migrate fixture str =
  beforeAll (setupDB migrate fixture) . afterAll (teardownDB migrate . fst) . describe str
