module Presenter.Model.Entities where

import Prelude
import Model
import Presenter.Model.RouteTypes
import Presenter.Model.StarExec
  ( SolverResult
  , JobResultStatus (..)
  , JobStatus)
import Presenter.Model.Types (Seconds, Name)
import qualified Data.Text as T
import Data.Maybe

-- ###### TYPE-CLASSES ######

class ResultEntity a where
  getSolverResult :: a -> SolverResult
  getResultStatus :: a -> JobResultStatus
  toJobID :: a -> JobID
  toResultID :: a -> JobResultID
  isResultComplete :: a -> Bool
  updateScore :: a -> Maybe Int -> a
  toScore :: a -> Maybe Int

class BenchmarkEntity a where
  toBenchmarkID :: a -> BenchmarkID
  toBenchmarkName :: a -> Name

class SolverEntity a where
  toSolverID :: a -> SolverID
  toSolverName :: a -> Name

class JobEntity a where
  toJobName :: a -> Name
  toJobStatus :: a -> JobStatus
  toJobDuration :: a -> Seconds

class FromJobResult a where
  fromJobResult :: JobResult -> Maybe a
  toJobResult :: a -> JobResult
  unwrapResults :: [JobResult] -> [a]
  unwrapResults = catMaybes . (map fromJobResult)
  wrapResults :: [a] -> [JobResult]
  wrapResults = map toJobResult

-- ###### DATA-TYPES ######

data Job =
  StarExecJob JobInfo
  | LriJob LriJobInfo
  deriving (Eq, Ord, Read, Show)

newtype Jobs = Jobs
  { getJobs :: [Job]
  }

data JobResult =
  StarExecResult JobResultInfo
  | LriResult LriResultInfo
  deriving (Eq, Ord, Read, Show)

newtype JobResults = JobResults
  { getResults :: [JobResult]
  }

data Pair  =
  StarExecPair JobPairInfo
  deriving (Eq, Ord, Read, Show)

data Benchmark =
  StarExecBenchmark BenchmarkInfo
  | LriBenchmark LriBenchmarkInfo
  deriving (Eq, Ord, Read, Show)

newtype Benchmarks = Benchmarks
  { getBenchmarks :: [Benchmark]
  }

data Solver =
  StarExecSolver SolverInfo
  | LriSolver LriSolverInfo
  deriving (Eq, Ord, Read, Show)

newtype Solvers = Solvers
  { getSolvers :: [Solver]
  }

-- ###### INSTANCES ######

-- #### ResultEntity ####

instance ResultEntity JobResult where
  getSolverResult (StarExecResult r) = getSolverResult r
  getSolverResult (LriResult r) = getSolverResult r

  getResultStatus (StarExecResult r) = getResultStatus r
  getResultStatus (LriResult r) = getResultStatus r

  toJobID (StarExecResult r) = toJobID r
  toJobID (LriResult r) = toJobID r

  toResultID (StarExecResult r) = toResultID r
  toResultID (LriResult r) = toResultID r

  isResultComplete (StarExecResult r) = isResultComplete r
  isResultComplete (LriResult r) = isResultComplete r

  updateScore (StarExecResult r) = StarExecResult . (updateScore r)
  updateScore (LriResult r) = LriResult . (updateScore r)

  toScore (StarExecResult r) = toScore r
  toScore (LriResult r) = toScore r

instance ResultEntity JobResultInfo where
  getSolverResult = jobResultInfoResult

  getResultStatus = jobResultInfoStatus

  toJobID = StarExecJobID . jobResultInfoJobId

  toResultID = StarExecResultID . jobResultInfoPairId

  isResultComplete r = jobResultInfoStatus r == JobResultComplete

  updateScore r s = r { jobResultInfoScore = s }

  toScore = jobResultInfoScore

instance ResultEntity LriResultInfo where
  getSolverResult = lriResultInfoResult

  getResultStatus _ = JobResultComplete

  toJobID = LriJobID . lriResultInfoJobId

  toResultID = LriResultID . lriResultInfoPairId

  isResultComplete _ = True

  updateScore r s = r { lriResultInfoScore = s }

  toScore = lriResultInfoScore

-- #### FromJobResult ####

instance FromJobResult JobResultInfo where
  fromJobResult (StarExecResult r) = Just r
  fromJobResult _ = Nothing
  toJobResult = StarExecResult

instance FromJobResult LriResultInfo where
  fromJobResult (LriResult r) = Just r
  fromJobResult _ = Nothing
  toJobResult = LriResult

-- #### BenchmarkEntity ####

instance BenchmarkEntity Benchmark where
  toBenchmarkID (StarExecBenchmark b) = toBenchmarkID b
  toBenchmarkID (LriBenchmark b) = toBenchmarkID b

  toBenchmarkName (StarExecBenchmark b) = toBenchmarkName b
  toBenchmarkName (LriBenchmark b) = toBenchmarkName b

instance BenchmarkEntity JobResult where
  toBenchmarkID (StarExecResult r) = toBenchmarkID r
  toBenchmarkID (LriResult r) = toBenchmarkID r

  toBenchmarkName (StarExecResult r) = toBenchmarkName r
  toBenchmarkName (LriResult r) = toBenchmarkName r

instance BenchmarkEntity JobResultInfo where
  toBenchmarkID = StarExecBenchmarkID . jobResultInfoBenchmarkId

  toBenchmarkName = jobResultInfoBenchmark

instance BenchmarkEntity LriResultInfo where
  toBenchmarkID = LriBenchmarkID . lriResultInfoBenchmarkId

  toBenchmarkName = lriResultInfoBenchmarkId

instance BenchmarkEntity BenchmarkInfo where
  toBenchmarkID = StarExecBenchmarkID . benchmarkInfoStarExecId

  toBenchmarkName = benchmarkInfoName

instance BenchmarkEntity LriBenchmarkInfo where
  toBenchmarkID = LriBenchmarkID . lriBenchmarkInfoBenchmarkId

  toBenchmarkName = lriBenchmarkInfoName

-- #### SolverEntity ####

instance SolverEntity Solver where
  toSolverID (StarExecSolver s) = toSolverID s
  toSolverID (LriSolver s) = toSolverID s

  toSolverName (StarExecSolver s) = toSolverName s
  toSolverName (LriSolver s) = toSolverName s

instance SolverEntity JobResult where
  toSolverID (StarExecResult r) = toSolverID r
  toSolverID (LriResult r) = toSolverID r

  toSolverName (StarExecResult r) = toSolverName r
  toSolverName (LriResult r) = toSolverName r

instance SolverEntity JobResultInfo where
  toSolverID = StarExecSolverID . jobResultInfoSolverId

  toSolverName = jobResultInfoSolver

instance SolverEntity LriResultInfo where
  toSolverID = LriSolverID . lriResultInfoSolverId

  toSolverName = lriResultInfoSolverId

instance SolverEntity SolverInfo where
  toSolverID = StarExecSolverID . solverInfoStarExecId

  toSolverName = solverInfoName

instance SolverEntity LriSolverInfo where
  toSolverID = LriSolverID . lriSolverInfoSolverId

  toSolverName = lriSolverInfoName

-- ###### HELPER ######

isStarExecJob :: Job -> Bool
isStarExecJob (StarExecJob _) = True
isStarExecJob _ = False

isStarExecResult :: JobResult -> Bool
isStarExecResult (StarExecResult _) = True
isStarExecResult _ = False

isLriResult :: JobResult -> Bool
isLriResult (LriResult _) = True
isLriResult _ = False