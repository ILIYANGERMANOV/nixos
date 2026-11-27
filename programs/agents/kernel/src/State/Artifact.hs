{- | A run's artifacts: the files and URLs it registers, so a fresh agent
resumes from them. A file is named by its absolute path and the SHA-256 and
size of the bytes read (the OCI descriptor's digest and size); its bytes are
kept as a 'Blob' when 'snapshotted'. A URL is an RFC 3986 absolute URI. Each
location has its own kinds, so a kind that fits no location cannot be built.
-}
module State.Artifact (
    Artifact (..),
    FileArtifact (..),
    FileKind (..),
    UrlKind (..),
    fileKindText,
    urlKindText,
    FileRef (..),
    AbsPath,
    absPath,
    absPathText,
    Uri,
    parseUri,
    uriText,
    uriRule,
    Sha256,
    sha256Of,
    parseSha256,
    sha256Text,
    Size (..),
    sizeOf,
    cap,
    snapshotted,
    keepsContent,
    Blob (..),
    blobKey,
    Snapshot (..),
    register,
    Contents (..),
    newest,
    resnapshot,
    blobsOf,
    originRepo,
) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.URI (parseAbsoluteURI)
import Numeric.Natural (Natural)
import State.Step.Artifact (Repo, parseRepo)
import System.FilePath (isAbsolute, normalise)

-- | What a run registered: a file, or a URL, each with a kind of its own.
data Artifact = File FileArtifact | Url UrlKind Uri
    deriving stock (Eq, Show)

-- | A registered file: what it is, and the bytes it held when read.
data FileArtifact = FileArtifact {kind :: FileKind, ref :: FileRef}
    deriving stock (Eq, Show)

-- | A file's kinds, as #552's Appendix B lists them; 'OtherFile' is its @other@.
data FileKind
    = Plan
    | Requirements
    | TaskList
    | Intent
    | Brief
    | Report
    | Notes
    | Research
    | Review
    | PrBody
    | Transcript
    | Download
    | OtherFile
    deriving stock (Eq, Show, Enum, Bounded)

-- | A URL's kinds, as Appendix B lists them; 'OtherUrl' is its @other@.
data UrlKind = Ticket | Issue | Pr | Doc | OtherUrl
    deriving stock (Eq, Show, Enum, Bounded)

-- | A file kind as the log and the CLI spell it: @other@ for 'OtherFile'.
fileKindText :: FileKind -> Text
fileKindText = \case
    Plan -> "plan"
    Requirements -> "requirements"
    TaskList -> "task_list"
    Intent -> "intent"
    Brief -> "brief"
    Report -> "report"
    Notes -> "notes"
    Research -> "research"
    Review -> "review"
    PrBody -> "pr_body"
    Transcript -> "transcript"
    Download -> "download"
    OtherFile -> "other"

-- | A URL kind as the log and the CLI spell it: @other@ for 'OtherUrl'.
urlKindText :: UrlKind -> Text
urlKindText = \case
    Ticket -> "ticket"
    Issue -> "issue"
    Pr -> "pr"
    Doc -> "doc"
    OtherUrl -> "other"

-- | A file as read: where it is, the digest of the bytes read, and their count.
data FileRef = FileRef {path :: AbsPath, sha256 :: Sha256, size :: Size}
    deriving stock (Eq, Show)

{- | An absolute POSIX path, as 'normalise' leaves it, so one file has one
spelling and the newest artifact per path is found by equality. Not a
'State.Step.Artifact.ShellPath': a registered file may hold any character a
path may, a space or a quote included. Built by 'absPath' alone.
-}
newtype AbsPath = AbsPath FilePath
    deriving stock (Eq, Ord, Show)

absPath :: FilePath -> Maybe AbsPath
absPath path
    | isAbsolute path && normalise path == path = Just (AbsPath path)
    | otherwise = Nothing

absPathText :: AbsPath -> FilePath
absPathText (AbsPath path) = path

{- | An RFC 3986 absolute URI (s4.3), kept as given: a scheme, no
@#fragment@. Built by 'parseUri' alone.
-}
newtype Uri = Uri Text
    deriving stock (Eq, Show)

parseUri :: Text -> Maybe Uri
parseUri raw
    | isJust (parseAbsoluteURI (Text.unpack raw)) = Just (Uri raw)
    | otherwise = Nothing

uriText :: Uri -> Text
uriText (Uri raw) = raw

-- | What 'parseUri' accepts, as a refusal names it.
uriRule :: Text
uriRule = "an absolute URI (RFC 3986 4.3), no #fragment"

{- | A SHA-256 digest (FIPS 180-4) as 64 lowercase hex: the OCI digest
without its @sha256:@ prefix, and the key of a 'Blob'.
-}
newtype Sha256 = Sha256 Text
    deriving stock (Eq, Ord, Show)

sha256Of :: ByteString -> Sha256
sha256Of =
    Sha256
        . Text.decodeLatin1
        . Lazy.toStrict
        . toLazyByteString
        . byteStringHex
        . SHA256.hash

-- | A digest as the log and the store spell it: 64 lowercase hex, nothing else.
parseSha256 :: Text -> Maybe Sha256
parseSha256 raw
    | Text.length raw == 64 && Text.all (`elem` ("0123456789abcdef" :: String)) raw =
        Just (Sha256 raw)
    | otherwise = Nothing

sha256Text :: Sha256 -> Text
sha256Text (Sha256 raw) = raw

-- | A file's size in bytes.
newtype Size = Size {bytes :: Natural}
    deriving stock (Eq, Ord, Show)

sizeOf :: ByteString -> Size
sizeOf = Size . fromIntegral . ByteString.length

-- | The most bytes a file's 'Blob' keeps, 1 MiB: a larger file is registered by its digest alone.
cap :: Size
cap = Size 1048576

{- | Whether a file of this kind and size keeps its bytes. A transcript
never does: it is registered by path and digest alone (#552).
-}
snapshotted :: FileKind -> Size -> Bool
snapshotted kind size = keepsContent kind && size <= cap

-- | Whether a file of this kind ever keeps its bytes, whatever its size.
keepsContent :: FileKind -> Bool
keepsContent = \case
    Plan -> True
    Requirements -> True
    TaskList -> True
    Intent -> True
    Brief -> True
    Report -> True
    Notes -> True
    Research -> True
    Review -> True
    PrBody -> True
    Transcript -> False
    Download -> True
    OtherFile -> True

-- | A file's bytes as the store keeps them, once per content.
newtype Blob = Blob ByteString
    deriving stock (Eq, Show)

-- | The key a blob is stored under: the digest of its bytes, never given apart from them.
blobKey :: Blob -> Sha256
blobKey (Blob bytes) = sha256Of bytes

-- | A file registered from the bytes read: its artifact, and its blob when 'snapshotted'.
data Snapshot = Snapshot {file :: FileArtifact, blob :: Maybe Blob}
    deriving stock (Eq, Show)

register :: FileKind -> AbsPath -> ByteString -> Snapshot
register kind path bytes =
    Snapshot
        { file = FileArtifact {kind, ref = FileRef {path, sha256 = sha256Of bytes, size}}
        , blob = if snapshotted kind size then Just (Blob bytes) else Nothing
        }
  where
    size = sizeOf bytes

-- | A file's bytes, read once, or none: it is gone or may not be read.
data Contents = Readable ByteString | Unreadable
    deriving stock (Eq, Show)

{- | The newest file artifact of each path, with its seq, of these artifacts
oldest first, each with its seq: what 'resnapshot' reads again.
-}
newest :: [(Natural, Artifact)] -> Map AbsPath (Natural, FileArtifact)
newest artifacts =
    Map.fromList [(file.ref.path, (n, file)) | (n, File file) <- artifacts]

{- | The files to register again, from the newest artifact of each path and
its bytes read now: one whose bytes changed, and the paths that could not be
read, which are skipped. A file whose bytes are the same, or one whose kind
never keeps its bytes (a transcript), adds nothing. Idempotent: run again on
its own output with the same bytes, it adds nothing.
-}
resnapshot :: [(FileArtifact, Contents)] -> ([Snapshot], [AbsPath])
resnapshot files =
    ( [ fresh
      | (artifact, Readable bytes) <- kept
      , let fresh = register artifact.kind artifact.ref.path bytes
      , fresh.file.ref.sha256 /= artifact.ref.sha256
      ]
    , [artifact.ref.path | (artifact, Unreadable) <- kept]
    )
  where
    kept = [file | file@(artifact, _) <- files, keepsContent artifact.kind]

{- | The blobs these artifacts register, from the bytes read for them: one
per 'snapshotted' file whose digest a read has. A file read that no artifact
names, or an artifact over the cap, adds none.
-}
blobsOf :: [ByteString] -> [Artifact] -> [Blob]
blobsOf bytesRead artifacts =
    [ blob
    | File file <- artifacts
    , snapshotted file.kind file.ref.size
    , Just blob <- [Map.lookup file.ref.sha256 byKey]
    ]
  where
    byKey = Map.fromList [(blobKey blob, blob) | blob <- map Blob bytesRead]

{- | The GitHub repo of a git remote's URL, as @git remote get-url@ prints
it: @ssh://@, @http://@ or @https://@ (a port allowed), or scp's
@host:path@, each with an optional @user\@@, @.git@ and trailing @/@. A host
other than github.com (any case, RFC 3986 s3.2.2) is no GitHub repo. A path
of more than two parts, or an scp path starting at @/@, is none either.
-}
originRepo :: Text -> Maybe Repo
originRepo raw = parseRepo . bare =<< githubPath
  where
    githubPath = case Text.breakOn "://" raw of
        (scheme, rest)
            | Just remote <- Text.stripPrefix "://" rest ->
                if scheme `elem` ["ssh", "http", "https"]
                    then
                        let (authority, path) = Text.breakOn "/" remote
                         in onGithub (Text.takeWhile (/= ':') (hostOf authority))
                                =<< Text.stripPrefix "/" path
                    else Nothing
        _ ->
            -- scp: no slash before the first colon, else git reads a local path.
            let (authority, path) = Text.breakOn ":" raw
             in if Text.any (== '/') authority
                    then Nothing
                    else onGithub (hostOf authority) =<< Text.stripPrefix ":" path
    hostOf = snd . Text.breakOnEnd "@"
    onGithub host path
        | Text.toLower host == "github.com" = Just path
        | otherwise = Nothing
    bare path =
        let trimmed = fromMaybe path (Text.stripSuffix "/" path)
         in fromMaybe trimmed (Text.stripSuffix ".git" trimmed)
