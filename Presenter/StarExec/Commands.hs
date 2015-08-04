{- |
  StarExecCommands: Module that contains and handles all request to the
  starexec-cluster
-}

module Presenter.StarExec.Commands
  ( getJobResults
  , getJobPairInfo
  , getJobInfo
  , getBenchmarkInfo
  , getBenchmark
  , getSolverInfo
  , getPostProcInfo
  , pushJobXML
  , getSpaceXML
  , getDefaultSpaceXML
  , pauseJobs , resumeJobs, rerunJobs
  , addJob, addSolver
  ) where

import Import
import Prelude (head)
import qualified Data.Text.Encoding as TE
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.IO ( stderr )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import Network.HTTP.Conduit
import Network.HTTP.Types.Status
import qualified Network.HTTP.Client.MultipartFormData as MP
import Presenter.StarExec.Urls
import Presenter.PersistHelper
import Presenter.StarExec.Connection
import qualified Codec.Archive.Zip as Zip
import qualified Data.Csv as CSV
import qualified Data.Vector as Vector
import Text.HTML.DOM
import Text.HTML.TagSoup
import Text.XML.Cursor
import Codec.Compression.GZip
import qualified Data.Map as M
import Data.Time.Clock
import Data.Time.Calendar

import Text.Hamlet.XML
import Text.XML
import qualified Data.Char
import Data.CaseInsensitive ()
import Data.Char (toLower)
import Control.Monad ( guard, when, forM )
import qualified Network.HTTP.Client.MultipartFormData as M
import qualified Network.HTTP.Client as C
import Data.List ( isSuffixOf, mapAccumL )
import Data.Maybe
import Data.Char ( isAlphaNum )
import Control.Monad.Logger
import Prelude (init,tail)

defaultDate :: UTCTime
defaultDate = UTCTime
  (fromGregorian 1970 1 1)
  (secondsToDiffTime 0)

(+>) :: BSC.ByteString -> BSC.ByteString -> BSC.ByteString
(+>) = BS.append

safeHead :: a -> [a] -> a
safeHead _ (x:_) = x
safeHead defaultVal [] = defaultVal

-- * internal Methods

decodeUtf8Body :: Response BSL.ByteString -> Text
decodeUtf8Body = TE.decodeUtf8 . BSL.toStrict . responseBody

cursorFromDOM :: BSL.ByteString -> Cursor
cursorFromDOM = fromDocument . Text.HTML.DOM.parseLBS

getFirstTitle :: Cursor -> Text
getFirstTitle c = head $ content h1
  where h1 = head $ descendant c >>= element "h1" >>= child

getJobInfoFieldset :: Cursor -> Cursor
getJobInfoFieldset c = getFieldsetByID c "detailField"
--getJobInfoFieldset c = head $ descendant c >>= element "fieldset" >>= attributeIs "id" "detailField"

getFirstFieldset :: Cursor -> Cursor
getFirstFieldset c = head $ getFieldsets c

getFieldsets :: Cursor -> [Cursor]
getFieldsets c = descendant c >>= element "fieldset"

getFieldsetByID :: Cursor -> Text -> Cursor
getFieldsetByID c _id = head $ getFieldsets c >>= attributeIs "id" _id

getTds :: Cursor -> [Cursor]
getTds c = descendant c >>= element "td" >>= child

constructJobInfo :: Int -> Text -> [Cursor] -> JobInfo
constructJobInfo _jobId title tds =
  let baseJobInfo = JobInfo _jobId
                            title
                            Incomplete
                            ""
                            "unkown"
                            "unkown"
                            False
                            True
                            defaultDate
                            Nothing
                            defaultDate
      getJobStatus t = case t of
                        "complete" -> Complete
                        _ -> Incomplete
      isCompl s = 0 < (T.count "complex" $ T.toLower s)
      parseTDs info xs =
        case xs of
          ("status":t:ts) ->
            parseTDs (info { jobInfoStatus = getJobStatus t }) ts
          ("created":t:ts) ->
            parseTDs (info { jobInfoDate = t }) ts
          ("postprocessor":t:ts) ->
            parseTDs (info { jobInfoPostProc = t }) ts
          ("preprocessor":t:ts) ->
            parseTDs (info { jobInfoPreProc = t }) ts
          ("description":t:ts) ->
            parseTDs (info { jobInfoIsComplexity = isCompl t }) ts
          (_:ts) -> parseTDs info ts
          _ -> info
      tds' = map (safeHead "" . content) tds
  in parseTDs baseJobInfo tds'

constructBenchmarkInfo :: Int -> Text -> [Cursor] -> BenchmarkInfo
constructBenchmarkInfo _benchmarkId title tds =
  let baseBenchmarkInfo = BenchmarkInfo _benchmarkId
                                        title
                                        ""
                                        defaultDate
      parseTDs info xs =
        case xs of
          ("name":t:ts) -> parseTDs
                              (info { benchmarkInfoType = t })
                              ts
          (_:ts) -> parseTDs info ts
          _ -> info
      tds' = map (safeHead "" . content) tds
  in parseTDs baseBenchmarkInfo tds'

constructSolverInfo :: Int -> Text -> [Cursor] -> SolverInfo
constructSolverInfo _solverId title tds =
  let baseSolverInfo = SolverInfo _solverId
                                  title
                                  ""
                                  defaultDate
      parseTDs info xs =
        case xs of
          ("description":t:ts) -> parseTDs
                                     (info { solverInfoDescription = t })
                                     ts
          (_:ts) -> parseTDs info ts
          _ -> info
      tds' = map (safeHead "" . content) tds
  in parseTDs baseSolverInfo tds'

constructPostProcInfo :: Int -> Text -> [Cursor] -> PostProcInfo
constructPostProcInfo _procId title tds =
  let basePostProcInfo = PostProcInfo _procId
                                      title
                                      ""
                                      defaultDate
      part (ys,zs) (x:y:xs) = part (x:ys,y:zs) xs
      part rest _           = rest
      (keys,vals) = part ([],[]) tds
      keys' = map (safeHead "" . content) keys
      vals' = map (safeHead "" . content . head . child) vals
      parse info xs = 
        case xs of
          ("description",v):zs -> parse
                                    (info { postProcInfoDescription = v })
                                    zs
          _:zs -> parse info zs
          _ -> info
  in parse basePostProcInfo $ zip keys' vals'

-- | create jobxml DOM according to spec
jobs_to_XML :: [ StarExecJob ] -> Document
jobs_to_XML js = Document (Prologue [] Nothing []) root [] where 
    t x = T.pack $ show x
    b x = T.pack $ map Data.Char.toLower $ show x
    -- path must be in  [_/\w\-\.\+\^=,!?:$%#@ ]*"
    -- but there is a strange '-' in Runtime_Complexity_-_Full_Rewriting etc.
    path_sanitize = T.filter $ \ c -> isAlphaNum c || c `elem` ("/_" :: String)
    root = Element "tns:Jobs" 
             (M.fromList [("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
                         ,("xsi:schemaLocation", "https://www.starexec.org/starexec/public/batchJobSchema.xsd batchJobSchema.xsd")
                         ,("xmlns:tns","https://www.starexec.org/starexec/public/batchJobSchema.xsd") ]) [xml|
       $forall j <- js
           <Job name="#{job_name j}">
             <JobAttributes>
               <description value="#{description j}">
               <queue-id value="#{t $ queue_id j}">
               <start-paused value="#{b $ start_paused j}">
               <cpu-timeout value="#{t $ cpu_timeout j}">
               <wallclock-timeout value="#{t $ wallclock_timeout j}">
               <mem-limit value="#{t $ mem_limit j}">
               <postproc-id value="#{t $ postproc_id j}">
             $forall p <- jobpairs j
                 <JobPair job-space-path="#{path_sanitize $ jobPairSpace p}" bench-id="#{t $ jobPairBench p}" config-id="#{t $ jobPairConfig p}">
      |]

-- | need to take care of Issue #34.
-- if jobpairs are like this:
-- [ non-empty, empty, ne, ne, ne, e, ne ]
-- then we produce an archive with the 5 non-empty jobs,
-- and the extra result is
-- [ Just 0, Nothing, Just 1, Just 2, Just 3, Nothing, Just 4 ]
jobs_to_archive :: [ StarExecJob ] -> Maybe (BSL.ByteString, [Maybe Int])
jobs_to_archive js = 
    let empty = null . jobpairs
        ne_js = filter ( not . empty ) js
        ( _, remap ) = mapAccumL 
            ( \ acc j -> if empty j 
            then (acc, Nothing) else (acc + 1, Just acc) ) 0 js
        d = jobs_to_XML ne_js
        e = Zip.toEntry "autojob.xml" 0 ( renderLBS def d ) 
        a = Zip.addEntryToArchive e Zip.emptyArchive
    in  if null ne_js then Nothing 
        else Just ( Zip.fromArchive a, remap )

-- * API

getJobInfo :: StarExecConnection -> Int -> Handler (Maybe JobInfo)
getJobInfo _ _jobId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                , path = jobInfoPath
                , queryString = "id=" +> (BSC.pack $ show _jobId)
                }
  resp <- sendRequest req
  let cursor = cursorFromDOM $ responseBody resp
      jobTitle = getFirstTitle cursor
  if "http" == T.take 4 jobTitle
    then return Nothing
    else do
      let fieldset = getJobInfoFieldset cursor
          tds = getTds fieldset
      return $ Just $ constructJobInfo _jobId jobTitle tds


getDefaultSpaceXML :: MonadIO m => FilePath -> m (Maybe Space)
getDefaultSpaceXML fp = do
    s <- liftIO $ BSL.readFile fp
    makeSpace s

getSpaceXML :: Int -> Handler (Maybe Space)
getSpaceXML _spaceId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                , path = downloadPath
                , queryString = "id=" +> (BSC.pack $ show _spaceId)
                            +> "&type=spaceXML"
                            +> "&includeattrs=false"
                }
  --liftIO $ putStrLn "### getSpaceXML -> ###"
  --liftIO $ print req
  resp <- sendRequest req
  --liftIO $ putStrLn "### <- getSpaceXML ###"

  makeSpace $ responseBody resp

makeSpace :: MonadIO m => BSL.ByteString -> m (Maybe Space)
makeSpace bs = do
  let archive = Zip.toArchive bs
      xml_entries = filter ( \ e -> isSuffixOf ".xml" $ Zip.eRelativePath e ) 
                 $ Zip.zEntries archive 
  let spaces =  case xml_entries of
        [ e ] -> do
          let cursor = cursorFromDOM $ Zip.fromEntry e
              root = laxElement "tns:Spaces" cursor >>= child
              walk :: [ Cursor ] -> [ Space ]
              walk r = r >>= laxElement "Space" >>= \ s -> return
                     Space { spId = case attribute "id" s of
                                 [ i ] -> read $ T.unpack i ; _ -> -1
                           , spName = case attribute "name" s of
                                 [ n ] -> n ; _ -> "noname"
                           , benchmarks = map ( read . T.unpack )
                             $ child s >>= laxElement "benchmark" >>= attribute "id" 
                           , children = child s >>= \ c ->  walk [c]
                           }
          walk root
        _ -> []

  case spaces of
      [s] -> return $ Just s
      _ -> do
          liftIO $ putStrLn "====== no space ======"
          return Nothing
    
getBenchmark :: StarExecConnection -> Int -> Handler (BSL.ByteString)
getBenchmark _ bmId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                      , queryString = "limit=-1"
                      , path = getURL benchmarkPath [("{bmId}", show bmId)]
                      }
  resp <- sendRequest req
  return $ responseBody resp
  
getBenchmarkInfo :: StarExecConnection -> Int -> Handler (Maybe BenchmarkInfo)
getBenchmarkInfo _ _benchmarkId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                , path = benchmarkInfoPath
                , queryString = "id=" +> (BSC.pack $ show _benchmarkId)
                }
  resp <- sendRequest req
  let cursor = cursorFromDOM $ responseBody resp
      benchmarkTitle = getFirstTitle cursor
  if "http" == T.take 4 benchmarkTitle
    then return Nothing
    else do
      let detailFieldset = getFirstFieldset cursor
          typeFieldset = getFieldsetByID cursor "fieldType"
          detailTds = getTds detailFieldset
          typeTds = getTds typeFieldset
      return $ Just $ constructBenchmarkInfo
        _benchmarkId benchmarkTitle $ detailTds ++ typeTds

getSolverInfo :: StarExecConnection -> Int -> Handler (Maybe SolverInfo)
getSolverInfo _ _solverId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                , path = solverInfoPath
                , queryString = "id=" +> (BSC.pack $ show _solverId)
                }
  resp <- sendRequest req
  let cursor = cursorFromDOM $ responseBody resp
      solverTitle = getFirstTitle cursor
  if "http" == T.take 4 solverTitle
    then return Nothing
    else do
      let detailFieldset = getFirstFieldset cursor
          tds = getTds detailFieldset
      return $ Just $ constructSolverInfo
        _solverId solverTitle tds

getPostProcInfo :: StarExecConnection -> Int -> Handler (Maybe PostProcInfo)
getPostProcInfo _ _procId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                , path = postProcPath
                , queryString = "type=post&id=" +> (BSC.pack $ show _procId)
                }
  resp <- sendRequest req
  let cursor = cursorFromDOM $ responseBody resp
      procTitle :: Text
      procTitle = getFirstTitle cursor
      procName :: Text
      procName = T.unwords $ filter (  /= "edit" ) $ T.words procTitle
  liftIO $ T.hPutStrLn stderr $ procTitle
  if "http" == T.take 4 procTitle
    then return Nothing
    else do
      let detailFieldset = getFirstFieldset cursor
          tds = getTds detailFieldset
      return $ Just $ constructPostProcInfo
        _procId procName tds

getJobResults :: StarExecConnection -> Int -> Handler [JobResultInfo]
getJobResults _ _jobId = do
  sec <- parseUrl starExecUrl
  let req = sec { method = "GET"
                , path = downloadPath
                , queryString = "id=" +> (BSC.pack $ show _jobId)
                                +> "&type=job&returnids=true"
                }
  resp <- sendRequest req
  let archive = Zip.toArchive $ responseBody resp
      insertId ji = ji { jobResultInfoJobId = _jobId }
  jobs <- case Zip.zEntries archive of
            entry:_ -> do
              -- liftIO $ BSL.writeFile ((show _jobId) ++ ".csv") $ Zip.fromEntry entry
              let eitherVector = CSV.decodeByName $ Zip.fromEntry entry
              case eitherVector of
                Left msg -> do
                  liftIO $ putStrLn msg
                  return []
                Right (_, jobInfos) ->
                  return $ map insertId $ Vector.toList jobInfos
            [] -> return []
  return jobs

getJobPairInfo :: StarExecConnection -> Int -> Handler (Maybe JobPairInfo)
getJobPairInfo _ _pairId = do
  sec <- parseUrl starExecUrl
  let reqStdout = sec { method = "GET"
                      , queryString = "limit=-1"
                      , path = getURL pairStdoutPath [("{pairId}", show _pairId)]
                      }
      reqLog = sec { method = "GET"
                   , path = getURL pairLogPath [("{pairId}", show _pairId)]
                   }
  respStdout <- sendRequest reqStdout
  if 200 /= (statusCode $ responseStatus respStdout)
    then return Nothing
    else do
      respLog <- sendRequest reqLog
      mPersistJobResult <- getPersistJobResult $ StarExecPairID _pairId
      let resultStatus = case mPersistJobResult of
                            Nothing -> JobResultUndetermined
                            Just jr -> getResultStatus jr
          stdout = responseBody respStdout
          htmlProof = getHtmlProof stdout
      return $ Just $ JobPairInfo _pairId
                                  (BSL.toStrict $ compress stdout)
                                  (BSL.toStrict $ compress $ responseBody respLog)
                                  htmlProof
                                  resultStatus
  where
    getHtmlProof :: BSL.ByteString -> Maybe BS.ByteString
    getHtmlProof bsl =
      let text = TE.decodeUtf8 $ BSL.toStrict bsl
          tLines = T.lines text
          tContent = drop 1 $ takeWhile isNoSuffixOf tLines
          t = T.dropWhile (/='<') $ T.unlines $ map removeTimeStamp tContent
      in case parseTags t of
            [] -> Nothing
            _ -> Just $ BSL.toStrict $ compress $ BSL.fromStrict $ TE.encodeUtf8 t
    removeTimeStamp t = T.drop 1 $ T.dropWhile (/='\t') t
    isNoSuffixOf line = not $ "EOF" `T.isSuffixOf` line

-- | description of the request object: see
-- org.starexec.command.Connection:uploadXML

pushJobXML :: Int -> [StarExecJob] -> Handler [StarExecJob]
pushJobXML sId jobs = do
  jss <- forM jobs $ \ job -> pushJobXML_bulk sId [job]
  return $ concat jss

-- FIXME: for large jobs, this is risky (it will no return, but time-out)
-- so we should send jobs one-by-one

pushJobXML_bulk :: Int -> [StarExecJob] -> Handler [StarExecJob]
pushJobXML_bulk sId jobs = do
  js <- pushJobXMLStarExec sId jobs
  registerJobs $ catMaybes $ map jobid js
  return js


pushJobXMLStarExec :: Int -> [StarExecJob] -> Handler [StarExecJob]
pushJobXMLStarExec sId jobs = case jobs_to_archive jobs of
  Nothing -> return jobs
  Just (bs, remap) -> do
    sec <- parseUrl starExecUrl
    req <- M.formDataBody [ M.partBS "space" ( BSC.pack $ show sId ) 
         , M.partFileRequestBody "f" "command.zip" $ C.RequestBodyLBS bs
         ] $ sec { method = "POST", path = pushjobxmlPath, responseTimeout = Nothing }

    let info = mconcat $ do
          job <- jobs
          return $ "Job " <> description job
              <> " num. pairs: " <> T.pack (show $ length $ jobpairs job) <> ","
    logWarnN $ "sending JobXML for " <> info          
    -- replace False with True to write the job file to disk 
    when (False) $ do
        liftIO $ BSL.writeFile "command.zip" bs

    -- liftIO $ print req
    
    resp <- sendRequest req

    -- the job ids are in the returned cookie.
    -- if there are more, then it's a comma-separated list
    -- Cookie {cookie_name = "New_ID", cookie_value = "2818", ... }
    
    let cs = destroyCookieJar $ responseCookieJar resp

    let vs = do c <- cs ; guard $ cookie_name c == "New_ID" ; return $ cookie_value c
        cut' c s = if null s then []
                  else let (pre,post) = span (/= c) s
                       in  pre : cut' c ( drop 1 post)


    logWarnN $ "done sending JobXML for " <> info <> " received vs = " <> T.pack (show vs)

    return $ case vs of
         [] ->  jobs
         [s] -> do
             let ids = map read $ cut' ',' 

-- FIXME, actually EXPLAINME:
-- single job: 
-- Cookie {cookie_name = "New_ID", cookie_value = "3048"
-- multiple jobs: 
-- Cookie {cookie_name = "New_ID", cookie_value = "\"3049,3050,3051,3052,3053\""
                     $ filter ( /= '"' ) 

                     $ BSC.unpack s
             (j, mpos) <- zip jobs remap
             let ji = case mpos of 
                     Nothing -> Nothing
                     Just pos -> let i = ids !! pos in
                                 if i > 0 then Just i else Nothing
             return $ j { jobid = ji }

pauseJobs :: [JobID] -> Handler ()
pauseJobs ids = do
  logWarnN $ "pausing jobs " <> T.pack (show ids)
  forM ids $ pauseJob
  logWarnN $ "done pausing jobs " <> T.pack (show ids)

pauseJob (StarExecJobID id) = do  
  sec <- parseUrl starExecUrl
  let req = sec { method = "POST"
                , path = getURL pausePath [("{id}", show id)]
                }
  resp <- sendRequest req
  logWarnN $ T.pack $ show resp
  return ()

resumeJobs :: [JobID] -> Handler ()
resumeJobs ids = do
  logWarnN $ "resuming jobs " <> T.pack (show ids)
  forM ids $ resumeJob
  logWarnN $ "done resuming jobs " <> T.pack (show ids)

resumeJob (StarExecJobID id) = do  
  sec <- parseUrl starExecUrl
  let req = sec { method = "POST"
                , path = getURL resumePath [("{id}", show id)]
                }
  resp <- sendRequest req
  logWarnN $ T.pack $ show resp
  return ()

rerunJobs :: [JobID] -> Handler ()
rerunJobs ids = do
  logWarnN $ "re-running jobs " <> T.pack (show ids)
  forM ids $ rerunJob
  logWarnN $ "done re-running jobs " <> T.pack (show ids)

rerunJob (StarExecJobID id) = do  
  sec <- parseUrl starExecUrl
  let req = sec { method = "POST"
                , path = getURL rerunPath [("{id}", show id)]
                }
  resp <- sendRequest req
  logWarnN $ T.pack $ show resp
  return ()

{-

copy : Boolean – If true, deep copies of all the given solvers are made first, and then the new solvers are
referenced in the given space. If false, solvers are simply referenced in the new space without being copied.

copyToSubspaces : Boolean – If true, solvers will be associated with every space in the hierarchy rooted at the
given space. Otherwise, they will be associated only with the given space.

fromSpace : integer – If not null, then this is the ID of a space containing all the solvers in selectedIds[] that you
have permission to copy solvers out of. If null, so such space is used, and you must be the owner of the solvers to
have permission to use them.

Description: Given a list of solvers, places the benchmarks into the given space. If copy is true, the
benchmarks are first copied. Otherwise, the benchmarks are just linked into the new space.

Returns: A jSON string containing a status object.

-}

type SpaceID = Int

addSolver :: SpaceID -- ^ toSpace
          -> [Int] -- ^ starexec-solverid
          -> Bool -- ^ copy
          -> Bool -- ^ copyToSubspaces
          -> Maybe SpaceID -- ^ fromSpace
          -> Handler ()
addSolver toSpace sids copy copyToSubspaces fromSpace = do
  base <- parseUrl starExecUrl

  logWarnN $ T.pack $ unwords [ "addSolver", show toSpace, show sids, show copy, show copyToSubspaces, show fromSpace ]

  let req = urlEncodedBody
            ( [ ("selectedIds", listify sids)
              , ("copy", boolean copy)
              , ("copyToSubspaces", boolean copyToSubspaces)
              ] ++
      -- guessing here, cf.
      -- http://starexec.lefora.com/topic/59/doc-request-explain-null-parameter-type-Integer
              case fromSpace of
                Just fsp -> [ ( "fromSpace", BSC.pack $ show fsp) ]
                Nothing -> []
            )
            $ base
            { method = "POST"
            , path = getURL addSolverPath [("{spaceId}", show toSpace)]
            }

  logWarnN $ T.pack $ show req
  case requestBody req of
    RequestBodyLBS bs -> logWarnN $ T.pack $ show bs
    _ -> return ()
  resp <- sendRequest req
  logWarnN $ T.pack $ show resp

boolean :: Bool -> BSC.ByteString
boolean flag = BSC.pack $ map toLower $ show flag

-- | wild guess here, cf.
-- http://starexec.lefora.com/topic/58/doc-request-exact-syntax-Integer-urlencoded-parameter
-- assuming the syntax is "1,2,3"
-- (comma-sep, in string quotes)
listify :: [ Int ] -> BSC.ByteString
listify [x] = BSC.pack $ show x
listify xs = BSC.pack $ show $ tail $ init $ show xs


{-

addJob:

name : String – The name to give the job
desc : String – The description to give the job.
preProcess : Integer – The ID of the pre processor to use. Can be excluded.
seed : Integer – A number that will be passed into the pre processor for every pair.
postProcess : Integer – The ID of the post processor to use. Can be excluded.
queue : Integer – The ID of the queue to run the job on.
spaceId : Integer – The ID of the space to put the job in.
cpuTimeout : Integer – The CPU timeout, in seconds, to enforce.
wallclockTimeout : Integer – The wallclock timeout, in seconds, to enforce.
maxMem : Float – The maximum memory limit, in gigabytes.
pause : Boolean – If true, job will start out paused. If false, job will start upon creation.
runChoice : String – Controls how job pairs are created, and can be either “keepHierarchy” or “choose”. In
“keepHierarchy”, a job is run using all benchmarks that are in the space hierarchy rooted at the spot that the job
was created, and every benchmark is executed by every solver configuration of every solver in the same space.
In “quickJob,” a single job pair is created, using the given solver and the given text to use as a new benchmark.
In “choose”, a list of configurations is provided to use in the job.
configs : [Integer] – The list of configurations to use in the job. Only applies if runChoice is “choose”

benchChoice : String – Only applies if runChoice is “choose”. Describes how to select benchmarks for the job.
Must be one of “runAllBenchInSpace”, “runAllBenchInHierarchy”, “runChosenFromSpace”. If
“runAllBenchInSpace”, all benchmarks in the space the job is being uploaded to will be used. If
"runAllBenchInHierarchy", all benchmarks in the entire hierarchy will be used. If "runChosenFromSpace", then
benchmarks must be provided.
bench : [Integer] – The list of benchmarks to use in the job. Only applies if benchChoice is
"runChosenFromSpace".
traversal : String – Controls the order in which job pairs are executed. Can be either “depth” or “robin.” With
“depth,” all the job pairs in a single space will be executed before moving onto another space. With “robin,”
each space in the job will have a single pair executed before any space has a second pair executed, and so on.
Description: Creates a new job with the given parameters.
Returns: An HTTP redirect to the spaces page on success, and an HTTP message with an error code and error
message on failure.
Return Cookies
New_ID : Integer – On success, contains the ID of the new job.


-}

addJob = error "addJob"
