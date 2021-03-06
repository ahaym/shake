
module General.Fence(
    Fence, newFence, signalFence, waitFence, testFence,
    exceptFence
    ) where

import Control.Monad
import Control.Monad.IO.Class
import Data.Maybe
import Data.Either.Extra
import Data.Functor
import Data.IORef.Extra
import Prelude


---------------------------------------------------------------------
-- FENCE

-- | Like a barrier, but based on callbacks
newtype Fence m a = Fence (IORef (Either (a -> m ()) a))
instance Show (Fence m a) where show _ = "Fence"

newFence :: MonadIO m => IO (Fence m a)
newFence = Fence <$> newIORef (Left $ const $ return ())

signalFence :: MonadIO m => Fence m a -> a -> m ()
signalFence (Fence ref) v = join $ liftIO $ atomicModifyIORef' ref $ \x -> case x of
    Left queue -> (Right v, queue v)
    Right v -> error "Shake internal error, signalFence called twice on one Fence"

waitFence :: MonadIO m => Fence m a -> (a -> m ()) -> m ()
waitFence (Fence ref) call = join $ liftIO $ atomicModifyIORef' ref $ \x -> case x of
    Left queue -> (Left (\a -> queue a >> call a), return ())
    Right v -> (Right v, call v)

testFence :: Fence m a -> IO (Maybe a)
testFence (Fence x) = either (const Nothing) Just <$> readIORef x


---------------------------------------------------------------------
-- FENCE COMPOSITES

exceptFence :: MonadIO m => [Fence m (Either e r)] -> m (Fence m (Either e [r]))
exceptFence xs = do
    -- number of items still to complete, becomes negative after it has triggered
    todo <- liftIO $ newIORef $ length xs
    fence <- liftIO newFence

    forM_ xs $ \x -> waitFence x $ \res ->
        join $ liftIO $ atomicModifyIORef' todo $ \i -> case res of
            Left e | i >= 0 -> (-1, signalFence fence $ Left e)
            _ | i == 1 -> (-1, signalFence fence . Right =<< liftIO (mapM (fmap (fromRight' . fromJust) . testFence) xs))
              | otherwise -> (i-1, return ())
    return fence
