module ConceptAnalysis.DotGraph where

import Import

import qualified Data.Text.Lazy as TL
import           Data.Graph.Inductive (mkGraph, Gr)
import Data.GraphViz (graphToDot, GraphvizParams, nonClusteredParams)
-- import Data.GraphViz.Types.Graph 
import Data.GraphViz.Printing (renderDot, toDot)


-- global_graph_attributes ::
-- global_graph_attributes = 

dotted_graph :: String
dotted_graph = TL.unpack $ renderDot $ toDot $ graphToDot graph_params $ graph
-- renderDot :: DotCode -> Text
-- graphToDot :: (Ord cl, Graph gr) => GraphvizParams Node nl el cl l -> gr nl el -> DotGraph Node

graph :: Gr TL.Text TL.Text
graph = mkGraph [ (2,"one"), (4,"three"), (5,"") ] [ (2,4,"edge label") ]
-- mkGraph :: [LNode a] -> [LEdge b] -> gr a b

graph_params :: GraphvizParams n TL.Text TL.Text () TL.Text
graph_params = nonClusteredParams


