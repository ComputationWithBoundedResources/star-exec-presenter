module Model where

import Prelude
import Yesod
import Data.Text (Text)
import Data.ByteString (ByteString)
import Database.Persist.Quasi
import Data.Typeable (Typeable)
import StarExec.Types (JobStatus, SolverResult)

-- You can define all of your database entities in the entities file.
-- You can find more information on persistent and how to declare entities
-- at:
-- http://www.yesodweb.com/book/persistent/
share [mkPersist sqlOnlySettings, mkMigrate "migrateAll"]
    $(persistFileWith lowerCaseSettings "config/models")
