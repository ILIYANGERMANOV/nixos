{- | The read side of the store (#552 s9): @state report@'s fixed reports
and @state sql@'s read-only SELECT, as the command line asks for them. Only
these read the projections; a command that decides reads the fold.
-}
module State.Cli.Query (
    Report (..),
    reportName,
    Window (..),
    parseSince,
    SqlRefusal (..),
) where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, zonedTimeToUTC)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import State.Run.Event (RunId)

-- | A fixed report: its columns are the body's table (#552 slice 6).
data Report = RunsReport | StepsReport | SignalsReport | GapsReport | WaitsReport
    deriving stock (Eq, Show, Enum, Bounded)

-- | The report's name on the command line.
reportName :: Report -> Text
reportName = \case
    RunsReport -> "runs"
    StepsReport -> "steps"
    SignalsReport -> "signals"
    GapsReport -> "gaps"
    WaitsReport -> "waits"

{- | The rows a report keeps: at or after this time, by the row's own time,
and of this run, each when given.
-}
data Window = Window {since :: Maybe UTCTime, run :: Maybe RunId}
    deriving stock (Eq, Show)

{- | A @--since@ time: an RFC 3339 s5.6 date-time, any offset and any
fraction, as UTC. A fraction past the millisecond rounds up, as the store
keeps whole milliseconds: a row stored at a millisecond before the time is
before it still.
-}
parseSince :: Text -> Maybe UTCTime
parseSince raw =
    roundedUp
        -- time's ISO 8601 format for a zoned time takes an offset only: Z is UTC's.
        <$> (iso8601ParseM text <|> zonedTimeToUTC <$> iso8601ParseM text)
  where
    text = Text.unpack raw
    roundedUp =
        posixSecondsToUTCTime
            . (\s -> fromInteger (ceiling (s * 1000)) / 1000)
            . utcTimeToPOSIXSeconds

-- | Why @state sql@ runs no statement.
data SqlRefusal
    = -- | A guard denied it: it would write, attach, run a PRAGMA or recurse.
      SqlNotReadOnly
    | -- | It holds no statement, or more than one.
      SqlNotOneStatement
    | -- | SQLite could not run it, in SQLite's words.
      SqlError Text
    deriving stock (Eq, Show)
