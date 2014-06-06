Certified Solver, which takes previous results of other solvers to test them
    -> maybe as post-processor
    -> or additional functionality with SE

## Model

    Solver

    Benchmark

    Job

getJobInfo:
https://www.starexec.org/starexec/secure/download?id=1095&type=job&returnids=true
id -> job-id
type -> job
returnids -> true

getJobPair:
https://www.starexec.org/starexec/secure/download?id=12185856&type=jp_output
id -> job-pair-id (see result of getJobInfo)

# TODOs 140519:

## 2D-Overview of solver and benchmarks
  * build a route, that manages multiple Solver
    * Solver on top, Benchmarks on the right
  * maybe implement an update-route, that pulls all current spaces and primitives in their hierarchy

## caching of job-pairs via seperate url
  * if the job-pair-infos are requested, store them in the DB
  * maybe zipped to decrease growth of db-data

## (incremental updates of running jobs)
  * check DB wether there is a completed job, pull the data from db

## (implement a in-app-user and deactivate the StarExec-Login-Process)
  * ask for .user- and .pass-Files on app-startup
  * save starexec-session in db


## 140602

* issue that zip of job-pair couldn't be downloaded

* top-level:

```
data Competition = Competition Text [Metacategory] 
data Metacategory = Metacategory Text [Category] -> solver nach rang in den categories
data Category = Category Text [JobId] -> solver nach YES/CERTIFIED/NO sortiert, evtl mit scoring -> SolverResult

instance PathPiece Competition where ... 


c :: Competition 
c = Competition "2014" 
[ Metacategory "Termination" 
[ Category "TRS_Standard" [ 13,14,15 ] 
, Category "SRS_Standard" [16,17,18] 
] 
... ] 
```