{- | Read-only SQL over the store (#552 s9): what @state sql@ and the
reports run. A second connection, opened read-only, that can neither write
nor attach a database, whatever the statement says:

- the file is opened with @SQLITE_OPEN_READONLY@;
- @sqlite3_limit(ATTACHED, 0)@: no database can be attached;
- an authorizer allows only SELECT, READ and FUNCTION, and denies a READ of
  any @pragma_*@ table-valued function, each a PRAGMA (D22). So a write,
  ATTACH, PRAGMA and a recursive CTE (D16) are refused when prepared;
- a statement @sqlite3_stmt_readonly@ calls a write is refused: VACUUM INTO
  asks the authorizer nothing.

Exactly one statement runs: the text must prepare to one, and what follows
it must prepare to none (sqlite3_prepare_v2's tail). Every call that can
run the authorizer is a safe FFI call, as a Haskell callback needs, and the
callback is freed only after the connection closed.

<https://www.sqlite.org/c3ref/set_authorizer.html>,
<https://www.sqlite.org/c3ref/limit.html>,
<https://www.sqlite.org/c3ref/stmt_readonly.html>,
<https://www.sqlite.org/c3ref/prepare.html>.
-}
module Effects.Store.Sql (
    ReadOnly,
    Refused (..),
    readOnly,
    select,
) where

import Control.Exception (bracket, finally, throwIO, try)
import Control.Monad (forM, (>=>))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Tsv (Cell (..), Result (..))
import Database.SQLite3 (
    ColumnType (..),
    Database,
    SQLData,
    SQLError (..),
    SQLOpenFlag (SQLOpenReadOnly),
    SQLVFS (SQLVFSDefault),
    Statement,
    StepResult (..),
 )
import Database.SQLite3 qualified as SQLite
import Database.SQLite3.Bindings (CDatabase, CStatement, c_sqlite3_prepare_v2)
import Database.SQLite3.Bindings.Types (CError (..), CNumBytes (..))
import Database.SQLite3.Direct (Database (..), Statement (..), Utf8 (..))
import Database.SQLite3.Direct qualified as Direct
import Foreign (FunPtr, Ptr, alloca, freeHaskellFunPtr, minusPtr, nullPtr, peek)
import Foreign.C (CInt (..), CString, peekCString)

-- | The guarded connection: read-only, no ATTACH, the authorizer installed.
newtype ReadOnly = ReadOnly Database

-- | Why a statement is not run.
data Refused
    = -- | It would write, attach, run a PRAGMA or recurse: a guard denied it.
      NotReadOnly
    | -- | It is no statement, or more than one.
      NotOneStatement
    | -- | SQLite could not prepare or run it, in SQLite's words.
      Failed Text
    deriving stock (Eq, Show)

{- | The store at this path, open read-only and guarded for one action. The
wait comes first: a PRAGMA is refused once the authorizer is in.
-}
readOnly :: FilePath -> (ReadOnly -> IO a) -> IO a
readOnly path act =
    bracket (wrap authorize) freeHaskellFunPtr $ \callback ->
        bracket open SQLite.close $ \db@(Database raw) -> do
            SQLite.exec db "PRAGMA busy_timeout = 5000"
            _ <- c_limit raw limitAttached 0
            installed <- c_set_authorizer raw callback nullPtr
            if installed == 0
                then act (ReadOnly db)
                else throwIO (userError "state sql: SQLite refused the authorizer")
  where
    open = SQLite.open2 (Text.pack path) [SQLOpenReadOnly] SQLVFSDefault

{- | The rows of one read-only statement, its parameters bound in order:
its column names and every row, or why it does not run.
-}
select :: ReadOnly -> Text -> [SQLData] -> IO (Either Refused Result)
select (ReadOnly db) sql params =
    prepared db sql >>= \case
        Left refused -> pure (Left refused)
        Right statement@(Statement raw) ->
            (`finally` SQLite.finalize statement) $ do
                readonly <- c_stmt_readonly raw
                if readonly == 0
                    then pure (Left NotReadOnly)
                    else
                        either (\(e :: SQLError) -> Left (Failed e.sqlErrorDetails)) Right
                            <$> try (SQLite.bind statement params >> resultOf statement)

{- | The one statement this text holds, prepared: refused when the
authorizer denied it, when it holds none, or when its tail holds another.
-}
prepared :: Database -> Text -> IO (Either Refused Statement)
prepared db@(Database raw) sql =
    ByteString.useAsCStringLen (encodeUtf8 sql) $ \(start, size) ->
        prepareAt start size >>= \case
            Left refused -> pure (Left refused)
            Right (Nothing, _) -> pure (Left NotOneStatement)
            Right (Just statement, rest) -> do
                let left = size - (rest `minusPtr` start)
                tail' <- prepareAt rest left
                case tail' of
                    Right (Nothing, _) -> pure (Right statement)
                    Right (Just another, _) -> do
                        SQLite.finalize another
                        SQLite.finalize statement
                        pure (Left NotOneStatement)
                    Left _ -> SQLite.finalize statement >> pure (Left NotOneStatement)
  where
    utf8 (Utf8 bytes) = decodeUtf8With lenientDecode bytes
    prepareAt start size =
        alloca $ \out -> alloca $ \rest -> do
            CError rc <-
                c_sqlite3_prepare_v2 raw start (CNumBytes (fromIntegral size)) out rest
            found <- peek out
            after <- peek rest
            case rc of
                -- SQLITE_OK
                0 ->
                    pure
                        (Right (if found == nullPtr then Nothing else Just (Statement found), after))
                -- SQLITE_AUTH: the authorizer denied it.
                23 -> pure (Left NotReadOnly)
                _ -> Left . Failed . utf8 <$> Direct.errmsg db

-- | Every row the statement steps to, each cell as SQLite gives it.
resultOf :: Statement -> IO Result
resultOf statement = do
    count <- SQLite.columnCount statement
    let columns = [0 .. count - 1]
    header <- forM columns (SQLite.columnName statement >=> maybe noName pure)
    Result header <$> rowsFrom columns
  where
    -- Only out of memory names none.
    noName = throwIO (userError "state sql: SQLite named no column")
    rowsFrom columns =
        SQLite.step statement >>= \case
            Done -> pure []
            Row -> (:) <$> traverse cellAt columns <*> rowsFrom columns
    cellAt column =
        SQLite.columnType statement column >>= \case
            NullColumn -> pure Null
            BlobColumn -> Blob <$> SQLite.columnBlob statement column
            -- SQLite's own text conversion spells a number.
            IntegerColumn -> Text <$> SQLite.columnText statement column
            FloatColumn -> Text <$> SQLite.columnText statement column
            TextColumn -> Text <$> SQLite.columnText statement column

{- | The authorizer: SELECT, READ and FUNCTION only, and no READ of a
@pragma_*@ table-valued function, matched without case, as SQLite matches names.
-}
authorize :: Authorizer
authorize _ action table _ _ _ = case action of
    -- SQLITE_READ
    20 -> do
        name <- if table == nullPtr then pure "" else peekCString table
        pure
            ( if "pragma_" `Text.isPrefixOf` Text.toLower (Text.pack name)
                then deny
                else allow
            )
    -- SQLITE_SELECT
    21 -> pure allow
    -- SQLITE_FUNCTION
    31 -> pure allow
    _ -> pure deny
  where
    -- SQLITE_OK, SQLITE_DENY
    allow = 0
    deny = 1

-- | @SQLITE_LIMIT_ATTACHED@.
limitAttached :: CInt
limitAttached = 7

type Authorizer =
    Ptr () -> CInt -> CString -> CString -> CString -> CString -> IO CInt

foreign import ccall "sqlite3_limit"
    c_limit :: Ptr CDatabase -> CInt -> CInt -> IO CInt

foreign import ccall "sqlite3_set_authorizer"
    c_set_authorizer :: Ptr CDatabase -> FunPtr Authorizer -> Ptr () -> IO CInt

foreign import ccall "sqlite3_stmt_readonly"
    c_stmt_readonly :: Ptr CStatement -> IO CInt

foreign import ccall "wrapper"
    wrap :: Authorizer -> IO (FunPtr Authorizer)
