-- | A run's artifacts: their URIs, digests, the snapshot rule and the GitHub repo of an origin.
module State.ArtifactSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, maybeToList)
import Data.Text qualified as Text
import Hedgehog (Gen, cover, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Artifact (
    Artifact (File),
    Blob (..),
    Contents (..),
    FileArtifact (..),
    FileKind (..),
    FileRef (..),
    Size (..),
    Snapshot (..),
    blobKey,
    blobsOf,
    cap,
    newest,
    originRepo,
    parseUri,
    register,
    resnapshot,
    sha256Of,
    sha256Text,
    snapshotted,
    uriText,
 )
import State.Run.Event (Repo (..))
import State.Run.EventGen (absolutePath, genAbsPath, genRepo)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Artifact" $ do
    describe "parseUri" $ do
        it "keeps an absolute URI as given" $
            uriText <$> parseUri "https://github.com/o/r/issues/7?q=a"
                `shouldBe` Just "https://github.com/o/r/issues/7?q=a"

        it "refuses a relative reference and a URI with a fragment" $
            map
                parseUri
                ["docs/plan.md", "//github.com/o/r", "https://github.com/o/r#readme"]
                `shouldBe` [Nothing, Nothing, Nothing]

    describe "sha256Of" $ do
        it "digests FIPS 180-4's \"abc\" in lowercase hex" $
            sha256Text (sha256Of "abc")
                `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        it "keys a blob by the digest of its content" . hedgehog $ do
            bytes <- forAll (Gen.bytes (Range.linear 0 64))
            blobKey (Blob bytes) === sha256Of bytes

    describe "snapshotted" $ do
        it "keeps a file of 1048576 bytes, the cap, and not one of 1048577" $
            map
                ( \n ->
                    isJust (register Notes (absolutePath "/n/big") (ByteString.replicate n 97)).blob
                )
                [1048576, 1048577]
                `shouldBe` [True, False]

        it "never keeps a transcript, however small" $
            map (snapshotted Transcript) [Size 0, cap] `shouldBe` [False, False]

        it "keeps the blob of every file it calls snapshotted, and of no other"
            . hedgehog
            $ do
                kind <- forAll Gen.enumBounded
                bytes <- forAll (Gen.bytes (Range.linear 0 64))
                let snapshot = register kind (absolutePath "/notes/a.md") bytes
                snapshot.blob
                    === if snapshotted kind snapshot.file.ref.size then Just (Blob bytes) else Nothing

    describe "blobsOf" $ do
        it "gives every snapshotted file artifact its blob, and no other artifact one"
            . hedgehog
            $ do
                kind <- forAll Gen.enumBounded
                bytes <- forAll (Gen.bytes (Range.linear 0 64))
                let snapshot = register kind (absolutePath "/notes/a.md") bytes
                blobsOf [bytes] [File snapshot.file] === maybeToList snapshot.blob

        it "stores a file under the cap as it was read" . hedgehog $ do
            bytes <- forAll (Gen.bytes (Range.linear 0 64))
            blobsOf [bytes] [File (register Notes (absolutePath "/notes/a.md") bytes).file]
                === [Blob bytes]

        it "adds no blob for bytes no artifact names" $
            blobsOf ["other"] [File (register Notes (absolutePath "/notes/a.md") "a").file]
                `shouldBe` []

    describe "resnapshot" $ do
        it
            "registers a changed file again, skips an unreadable one and adds nothing for the same bytes"
            $ let plan = (register Plan (absolutePath "/n/plan.md") "v1").file
                  brief = (register Brief (absolutePath "/n/brief.md") "b").file
                  notes = (register Notes (absolutePath "/n/notes.md") "n").file
               in resnapshot [(plan, Readable "v2"), (brief, Unreadable), (notes, Readable "n")]
                    `shouldBe` ([register Plan (absolutePath "/n/plan.md") "v2"], [absolutePath "/n/brief.md"])

        it "skips a transcript, changed or gone" $
            let transcript = (register Transcript (absolutePath "/t.jsonl") "a").file
             in resnapshot [(transcript, Readable "b"), (transcript, Unreadable)]
                    `shouldBe` ([], [])

        it "adds nothing when run again over the newest artifacts, the disk unchanged"
            . hedgehog
            $ do
                -- One registered file per path, and what each path reads now.
                files <-
                    forAll
                        (Map.elems . Map.fromList . map keyed <$> Gen.list (Range.linear 0 5) genFile)
                let disk = Map.fromList [(file.ref.path, now) | (file, now) <- files]
                    (fresh, _) = resnapshot files
                    registered =
                        newest (zip [1 ..] (map (File . fst) files <> map (File . (.file)) fresh))
                -- Else the second run has nothing new to see.
                cover 10 "a registered file changed" (not (null fresh))
                fst
                    ( resnapshot
                        [ (file, now)
                        | (_, file) <- Map.elems registered
                        , Just now <- [Map.lookup file.ref.path disk]
                        ]
                    )
                    === []

    describe "originRepo" $ do
        it "reads owner/name from each form git prints an origin in" $
            map
                originRepo
                [ "https://github.com/o/r.git"
                , "https://github.com/o/r/"
                , "http://github.com/o/r"
                , "https://x-access-token:t0k3n@github.com/o/r.git"
                , "ssh://git@github.com/o/r.git"
                , "ssh://git@github.com:22/o/r"
                , "git@github.com:o/r.git"
                , "github.com:o/r"
                , "git@GitHub.com:o/r.git/"
                ]
                `shouldBe` replicate 9 (Just (Repo "o" "r"))

        it "reads no repo off another host, a local path or a deeper path" $
            map
                originRepo
                [ "https://gitlab.com/o/r.git"
                , "git@gitlab.com:o/r.git"
                , "/srv/git/o/r.git"
                , "./github.com:o/r"
                , "https://github.com/o/r/tree/main"
                , "file://github.com/o/r"
                ]
                `shouldBe` replicate 6 Nothing

        it "reads back the repo it is rendered from, in any form" . hedgehog $ do
            -- GitHub refuses a repo named with a .git suffix: git strips it.
            repo <- forAll (Gen.filter (not . (".git" `Text.isSuffixOf`) . (.name)) genRepo)
            user <- forAll (Gen.element ["", "git@"])
            suffix <- forAll (Gen.element ["", ".git", "/", ".git/"])
            let repoPath = repo.owner <> "/" <> repo.name <> suffix
            form <-
                forAll
                    ( Gen.element
                        [ "ssh://" <> user <> "github.com/" <> repoPath
                        , "https://" <> user <> "github.com/" <> repoPath
                        , "http://" <> user <> "github.com/" <> repoPath
                        , user <> "github.com:" <> repoPath
                        ]
                    )
            originRepo form === Just repo
  where
    keyed file@(artifact, _) = (artifact.ref.path, file)

-- | A registered file and its bytes now: the same, changed or unreadable.
genFile :: Gen (FileArtifact, Contents)
genFile = do
    kind <- Gen.enumBounded
    filePath <- genAbsPath
    before <- Gen.bytes (Range.linear 0 8)
    now <-
        Gen.choice
            [ pure (Readable before)
            , Readable <$> Gen.bytes (Range.linear 0 8)
            , pure Unreadable
            ]
    pure ((register kind filePath before).file, now)
