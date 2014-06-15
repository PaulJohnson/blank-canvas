{-# LANGUAGE OverloadedStrings, TemplateHaskell, GADTs, KindSignatures, CPP, BangPatterns, ScopedTypeVariables #-}

module Graphics.Blank
        (
         -- * Starting blank-canvas
          blankCanvas
        , Options(..)
          -- ** 'send'ing to the Graphics 'Context'
        , Context       -- abstact
        , send
          -- * HTML5 Canvas API
          -- | See <http://www.nihilogic.dk/labs/canvas_sheet/HTML5_Canvas_Cheat_Sheet.pdf> for the JavaScript 
          --   version of this API.
        , Canvas        -- abstact
          -- ** Canvas element
        , size
        , toDataURL
          -- ** 2D Context
        , save
        , restore
          -- ** Transformation
        , scale
        , rotate
        , translate
        , transform
        , setTransform
          -- ** Image drawing
        , drawImage
          -- ** Compositing
        , globalAlpha
        , globalCompositeOperation
          -- ** Line styles
        , lineWidth
        , lineCap
        , lineJoin
        , miterLimit
          -- ** Colors, styles and shadows
        , strokeStyle
        , fillStyle
        , shadowOffsetX
        , shadowOffsetY
        , shadowBlur
        , shadowColor
        , createLinearGradient
        , createRadialGradient
        , createPattern
        , addColorStop
        , CanvasGradient
        , CanvasPattern
          -- ** Paths
        , beginPath
        , closePath
        , fill
        , stroke
        , clip
        , moveTo
        , lineTo
        , quadraticCurveTo
        , bezierCurveTo
        , arcTo
        , arc
        , rect
        , isPointInPath
          -- ** Text
        , font 
        , textAlign
        , textBaseline
        , fillText
        , strokeText
        , measureText
        , TextMetrics(..)
          -- ** Rectangles
        , clearRect
        , fillRect
        , strokeRect
          -- ** Pixel manipulation
        , createImageData
        , getImageData
        , putImageData
        , ImageData(..)
        -- * blank-canvas Extensions
        -- ** Reading from 'Canvas'
        , newImage
        , Image -- abstract class
        , CanvasImage -- abstract
         -- ** 'CanvasContext', and off-screen Canvas.
        , newCanvas
        , with
        , CanvasContext
        , top
         -- ** Debugging
        , console_log
        , eval
        , JSArg(..)
         -- ** Drawing Utilities
        , module Graphics.Blank.Utils
         -- ** Events
        , trigger 
        , eventQueue
        , wait
        , tryGet
        , flush
        , Event(..)
        , EventName
        , EventQueue
        -- ** GHCi API
        , splatCanvas
        -- ** Non-Prelude Data
        , Text
        ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Exception
import Network.Wai.Handler.Warp (run)
import Network.Wai (Middleware,remoteHost, responseLBS)
import qualified Network.HTTP.Types as H
import Network.Socket (SockAddr(..))
import System.IO.Unsafe (unsafePerformIO)
--import System.Mem.StableName
import Web.Scotty (scottyApp, get, file, middleware)
--import Network.Wai.Middleware.RequestLogger -- Used when debugging
--import Network.Wai.Middleware.Static
import qualified Web.KansasComet as KC
import Data.Aeson
import Data.Aeson.Types (parse)
import Data.String
import Data.Text (Text)

import Graphics.Blank.Events
import Graphics.Blank.Context
import Graphics.Blank.Canvas
import Graphics.Blank.Generated hiding (fillStyle,strokeStyle)
import qualified Graphics.Blank.Generated as Generated
import Graphics.Blank.JavaScript
import Graphics.Blank.Utils
import Paths_blank_canvas

-- | blankCanvas is the main entry point into blank-canvas.
-- A typical invocation would be
--
-- >module Main where
-- >
-- >import Graphics.Blank
-- >
-- >main = blankCanvas 3000 $ \ context -> do
-- >        send context $ do
-- >                moveTo(50,50)
-- >                lineTo(200,100)
-- >                lineWidth 10
-- >                strokeStyle "red"
-- >                stroke()
-- >


blankCanvas :: Options -> (Context -> IO ()) -> IO ()
blankCanvas opts actions = do
   dataDir <- getDataDir

   kComet <- KC.kCometPlugin


--   print dataDir

   app <- scottyApp $ do
--        middleware logStdoutDev
        middleware local_only
        -- use the comet
        let kc_opts :: KC.Options
            kc_opts = KC.Options { KC.prefix = "/blank", KC.verbose = if debug opts then 3 else 0 }

        KC.connect kc_opts $ \ kc_doc -> do
                -- register the events we want to watch for
                KC.send kc_doc $ unlines
                   [ "register(" ++ show nm ++ ");"
                   | nm <- events opts
                   ]

                queue <- atomically newTChan
                _ <- forkIO $ forever $ do
                        val <- atomically $ readTChan $ KC.eventQueue $ kc_doc
                        case fromJSON val of
                           Success (event :: Event) -> do
                                   atomically $ writeTChan queue event
                           _ -> return ()

                (actions $ Context kc_doc queue) `catch` \ (e :: SomeException) -> do
                        print ("Exception in blank-canvas application:"  :: String)
                        print e
                        throw e

        get "/" $ file $ dataDir ++ "/static/index.html"
        get "/jquery.js" $ file $ dataDir ++ "/static/jquery.js"
        get "/jquery-json.js" $ file $ dataDir ++ "/static/jquery-json.js"
        get "/kansas-comet.js" $ file $ kComet
        sequence_ [ get (fromString ("/" ++ nm)) $ file $ (root opts ++ "/" ++ nm) | nm <- static opts ]
        return ()

   run (port opts) app

-- | Sends a set of Canvas commands to the canvas. Attempts
-- to common up as many commands as possible. Should not crash.

send :: Context -> Canvas a -> IO a
send cxt commands = 
      send' top commands id 
  where
      send' :: CanvasContext -> Canvas a -> (String -> String) -> IO a
      send' c (Bind (Return a) k)    cmds = send' c (k a) cmds
      send' c (Bind (Bind m k1) k2)  cmds = send' c (Bind m (\ r -> Bind (k1 r) k2)) cmds
      send' c (Bind (Method cmd) k) cmds = send' c (k ()) (cmds . ((showJS c ++ ".") ++) . shows cmd . (";" ++))
      send' c (Bind (Command cmd) k) cmds = send' c (k ()) (cmds . shows cmd . (";" ++))
      send' c (Bind (Query query) k) cmds = do
              -- send the com
              uq <- atomically $ getUniq
              -- The query function returns a function takes the unique port number of the reply.
              sendToCanvas cxt (cmds . ((show query ++ "(" ++ show uq ++ "," ++ showJS c ++ ");") ++))
              v <- KC.getReply (theComet cxt) uq
              case parse (parseQueryResult query) v of
                Error msg -> fail msg
                Success a -> do
                        send' c (k a) id
      send' c (Bind (With c' m) k) cmds = send' c' (Bind m (With c . k)) cmds

      send' _ (With c m)           cmds = send' c m cmds
      send' _ (Return a)           cmds = do
              sendToCanvas cxt cmds
              return a
      send' c cmd                  cmds = send' c (Bind cmd Return) cmds


local_only :: Middleware
local_only f r = case remoteHost r of
                   SockAddrInet _  h | h == fromIntegral home
                                    -> f r
#if !defined(mingw32_HOST_OS) && !defined(_WIN32)
                   SockAddrUnix _   -> f r
#endif
                   _                ->  return $ responseLBS H.status403
                                                             [("Content-Type", "text/plain")]
                                                             "local access only"
 where
        home :: Integer
        home = 127 + (256 * 256 * 256) * 1

-- | splitCanvas is the GHCi entry point into blank-canvas.
-- A typical invocation would be
--
-- >
-- >
-- >import Graphics.Blank
-- > -- Adding commands to the canvas buffer
-- >splatCanvas 3000 $ (>> do { .. canvas commands .. })
-- > -- Replacing the buffer with some commands
-- >splatCanvas 3000 $ (\ _ -> do { .. canvas commands .. })


splatCanvas :: Options -> (Canvas () -> Canvas ()) -> IO ()
splatCanvas opts cmds = do
    optCh <- atomically $ do
        ports <- readTVar usedPorts
        uq <- getUniq
        case lookup (port opts) ports of
          Just ch -> do modifyTVar ch $ \ (_,orig) -> (uq,cmds orig)
                        return Nothing
          Nothing -> do ch <- newTVar (uq,cmds (return ()))
                        writeTVar usedPorts ((port opts,ch):ports)
                        return (Just ch)

    let full cmd = do
            clearCanvas
            cmd


    case optCh of
      Nothing -> return ()
      Just ch -> do
         let callback uq cxt = do
                (uq',cmd) <- atomically $ do
                        (uq',cmd) <- readTVar ch
                        check (uq' /= uq)     -- must be a new command
                        return (uq',cmd)
                send cxt $ full cmd -- issue the screen command (should check for failure)
                callback uq' cxt
         _ <- forkIO $ blankCanvas opts $ callback (-1)
         return ()

-- common TVar for all ports in use.
{-# NOINLINE usedPorts #-}
usedPorts :: TVar [(Int,TVar (Int,Canvas ()))]
usedPorts = unsafePerformIO $ newTVarIO []

{-# NOINLINE uniqVar #-}
uniqVar :: TVar Int
uniqVar = unsafePerformIO $ newTVarIO 0

getUniq :: STM Int
getUniq = do
    u <- readTVar uniqVar
    writeTVar uniqVar (u + 1)
    return u

-------------------------------------------------

data Options = Options 
        { port   :: Int            -- ^ which port do we issue the blank canvas using
        , events :: [EventName]    -- ^ which events does the canvas listen to
        , debug  :: Bool           -- ^ turn on debugging (default False)
        , remote :: Bool           -- ^ turn on remote access (default False)
        , static :: [String]       -- ^ path to images, and other static artifacts
        , root   :: String         -- ^ location of the static files (default .)
        } deriving Show
        
instance Num Options where
    (+) = error "no arithmetic for Blank Canvas Options"
    (-) = error "no arithmetic for Blank Canvas Options"
    (*) = error "no arithmetic for Blank Canvas Options"
    abs = error "no arithmetic for Blank Canvas Options"
    signum = error "no arithmetic for Blank Canvas Options"
    fromInteger n = Options { port = fromInteger n
                            , events = []
                            , debug = False
                            , remote = False
                            , static = []
                            , root = "." }


-------------------------------------------------
-- This is the monomorphic version, to stop "ambiguous" errors.

fillStyle :: Text -> Canvas ()
fillStyle = Generated.fillStyle

strokeStyle :: Text -> Canvas ()
strokeStyle = Generated.strokeStyle
