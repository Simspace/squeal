{-|
Module: Squeal.PostgreSQL.Session.Result
Description: results
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Get values from a `Result`.
-}

{-# LANGUAGE
    FlexibleContexts
  , GADTs
  , LambdaCase
  , OverloadedStrings
  , ScopedTypeVariables
  , TypeApplications
#-}

module Squeal.PostgreSQL.Session.Result
  ( Result (..)
  , getRow
  , firstRow
  , getRows
  , nextRow
  , cmdStatus
  , cmdTuples
  , ntuples
  , nfields
  , resultStatus
  , okResult
  , resultErrorMessage
  , resultErrorCode
  , liftResult
  ) where

import Control.Exception (throw)
import Control.Monad (when, (<=<))
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Traversable (for)
import Text.Read (readMaybe)
import UnliftIO (throwIO)

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text.Encoding as Text
import qualified Database.PostgreSQL.LibPQ as LibPQ
import qualified Generics.SOP as SOP

import Squeal.PostgreSQL.Session.Decode
import Squeal.PostgreSQL.Session.Exception

{- | `Result`s are generated by executing
`Squeal.PostgreSQL.Session.Statement`s
in a `Squeal.PostgreSQL.Session.Monad.MonadPQ`.

They contain an underlying `LibPQ.Result`
and a `DecodeRow`.
-}
data Result y where
  Result
    :: SOP.SListI row
    => DecodeRow row y
    -> LibPQ.Result
    -> Result y
instance Functor Result where
  fmap f (Result decode result) = Result (fmap f decode) result

-- | Get a row corresponding to a given row number from a `LibPQ.Result`,
-- throwing an exception if the row number is out of bounds.
getRow :: MonadIO io => LibPQ.Row -> Result y -> io y
getRow r (Result decode result) = liftIO $ do
  numRows <- LibPQ.ntuples result
  numCols <- LibPQ.nfields result
  when (numRows < r) $ throw $ RowsException "getRow" r numRows
  row' <- traverse (LibPQ.getvalue result r) [0 .. numCols - 1]
  case SOP.fromList row' of
    Nothing -> throw $ ColumnsException "getRow" numCols
    Just row -> case execDecodeRow decode row of
      Left parseError -> throw $ DecodingException "getRow" parseError
      Right y -> return y

-- | Intended to be used for unfolding in streaming libraries, `nextRow`
-- takes a total number of rows (which can be found with `ntuples`)
-- and a `LibPQ.Result` and given a row number if it's too large returns `Nothing`,
-- otherwise returning the row along with the next row number.
nextRow
  :: MonadIO io
  => LibPQ.Row -- ^ total number of rows
  -> Result y -- ^ result
  -> LibPQ.Row -- ^ row number
  -> io (Maybe (LibPQ.Row, y))
nextRow total (Result decode result) r
  = liftIO $ if r >= total then return Nothing else do
    numCols <- LibPQ.nfields result
    row' <- traverse (LibPQ.getvalue result r) [0 .. numCols - 1]
    case SOP.fromList row' of
      Nothing -> throw $ ColumnsException "nextRow" numCols
      Just row -> case execDecodeRow decode row of
        Left parseError -> throw $ DecodingException "nextRow" parseError
        Right y -> return $ Just (r+1, y)

-- | Get all rows from a `LibPQ.Result`.
getRows :: MonadIO io => Result y -> io [y]
getRows (Result decode result) = liftIO $ do
  numCols <- LibPQ.nfields result
  numRows <- LibPQ.ntuples result
  for [0 .. numRows - 1] $ \ r -> do
    row' <- traverse (LibPQ.getvalue result r) [0 .. numCols - 1]
    case SOP.fromList row' of
      Nothing -> throw $ ColumnsException "getRows" numCols
      Just row -> case execDecodeRow decode row of
        Left parseError -> throw $ DecodingException "getRows" parseError
        Right y -> return y

-- | Get the first row if possible from a `LibPQ.Result`.
firstRow :: MonadIO io => Result y -> io (Maybe y)
firstRow (Result decode result) = liftIO $ do
  numRows <- LibPQ.ntuples result
  numCols <- LibPQ.nfields result
  if numRows <= 0 then return Nothing else do
    row' <- traverse (LibPQ.getvalue result 0) [0 .. numCols - 1]
    case SOP.fromList row' of
      Nothing -> throw $ ColumnsException "firstRow" numCols
      Just row -> case execDecodeRow decode row of
        Left parseError -> throw $ DecodingException "firstRow" parseError
        Right y -> return $ Just y

-- | Lifts actions on results from @LibPQ@.
liftResult
  :: MonadIO io
  => (LibPQ.Result -> IO x)
  -> Result y -> io x
liftResult f (Result _ result) = liftIO $ f result

-- | Returns the number of rows (tuples) in the query result.
ntuples :: MonadIO io => Result y -> io LibPQ.Row
ntuples = liftResult LibPQ.ntuples

-- | Returns the number of columns (fields) in the query result.
nfields :: MonadIO io => Result y -> io LibPQ.Column
nfields = liftResult LibPQ.nfields

-- | Returns the result status of the command.
resultStatus :: MonadIO io => Result y -> io LibPQ.ExecStatus
resultStatus = liftResult LibPQ.resultStatus

{- |
Returns the command status tag from the SQL command
that generated the `Result`.
Commonly this is just the name of the command,
but it might include additional data such as the number of rows processed.
-}
cmdStatus :: MonadIO io => Result y -> io Text
cmdStatus = liftResult (getCmdStatus <=< LibPQ.cmdStatus)
  where
    getCmdStatus = \case
      Nothing -> throwIO $ ConnectionException "LibPQ.cmdStatus"
      Just bytes -> return $ Text.decodeUtf8 bytes

{- |
Returns the number of rows affected by the SQL command.
This function returns `Just` the number of
rows affected by the SQL statement that generated the `Result`.
This function can only be used following the execution of a
SELECT, CREATE TABLE AS, INSERT, UPDATE, DELETE, MOVE, FETCH,
or COPY statement,or an EXECUTE of a prepared query that
contains an INSERT, UPDATE, or DELETE statement.
If the command that generated the PGresult was anything else,
`cmdTuples` returns `Nothing`.
-}
cmdTuples :: MonadIO io => Result y -> io (Maybe LibPQ.Row)
cmdTuples = liftResult (getCmdTuples <=< LibPQ.cmdTuples)
  where
    getCmdTuples = \case
      Nothing -> throwIO $ ConnectionException "LibPQ.cmdTuples"
      Just bytes -> return $
        if ByteString.null bytes
        then Nothing
        else fromInteger <$> readMaybe (Char8.unpack bytes)

okResult_ :: MonadIO io => LibPQ.Result -> io ()
okResult_ result = liftIO $ do
  status <- LibPQ.resultStatus result
  case status of
    LibPQ.CommandOk -> return ()
    LibPQ.TuplesOk -> return ()
    _ -> do
      stateCodeMaybe <- LibPQ.resultErrorField result LibPQ.DiagSqlstate
      case stateCodeMaybe of
        Nothing -> throw $ ConnectionException "LibPQ.resultErrorField"
        Just stateCode -> do
          msgMaybe <- LibPQ.resultErrorMessage result
          case msgMaybe of
            Nothing -> throw $ ConnectionException "LibPQ.resultErrorMessage"
            Just msg -> throw . SQLException $ SQLState status stateCode msg

-- | Check if a `Result`'s status is either `LibPQ.CommandOk`
-- or `LibPQ.TuplesOk` otherwise `throw` a `SQLException`.
okResult :: MonadIO io => Result y -> io ()
okResult = liftResult okResult_ 

-- | Returns the error message most recently generated by an operation
-- on the connection.
resultErrorMessage
  :: MonadIO io => Result y -> io (Maybe ByteString)
resultErrorMessage = liftResult LibPQ.resultErrorMessage

-- | Returns the error code most recently generated by an operation
-- on the connection.
--
-- https://www.postgresql.org/docs/current/static/errcodes-appendix.html
resultErrorCode
  :: MonadIO io
  => Result y
  -> io (Maybe ByteString)
resultErrorCode = liftResult (flip LibPQ.resultErrorField LibPQ.DiagSqlstate)

execDecodeRow
  :: DecodeRow row y
  -> SOP.NP (SOP.K (Maybe ByteString)) row
  -> Either Text y
execDecodeRow decode = runDecodeRow decode
