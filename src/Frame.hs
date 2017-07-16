{-# LANGUAGE NamedFieldPuns #-}

module Frame(
  Frame(..),
  Type(..),
  Payload(..),
  readFrame,
  toString,
  writeFrame
) where

import qualified Control.Monad.Except as Except
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.Bits as Bits
import qualified Data.ByteString.Lazy as ByteString

import qualified Frame.Settings as FSettings

import Control.Monad.Except(ExceptT)
import Control.Monad.IO.Class(liftIO)
import Control.Monad.Trans.Class(lift)
import Data.Binary.Get(Get)
import Data.Binary.Put(Put)
import Data.Bits((.|.), (.&.))
import Data.ByteString.Lazy(ByteString)

import ProjectPrelude

data Type =
  TData |
  THeaders |
  TPriority |
  TRstStream |
  TSettings |
  TPushPromise |
  TPing |
  TGoaway |
  TWindowUpdate |
  TContinuation |
  TUnknown
  deriving Show

data Payload =
  PSettings FSettings.Payload |
  PBuffer ByteString

data Frame = Frame {
  fLength :: FrameLength,
  fType :: Type,
  fFlags :: FrameFlags,
  fStreamId :: StreamId,
  fPayload :: Payload
}

getLength :: Get FrameLength
getLength = do
  b3 <- Get.getWord8
  b2 <- Get.getWord8
  b1 <- Get.getWord8
  let shift b = Bits.shift (fromIntegral b)
  return (shift b3 16 .|. shift b2 8 .|. fromIntegral b1)

putLength :: FrameLength -> Put
putLength len =
  let shift n = fromIntegral . (.&. 0xFF) . Bits.shiftR n in do
  Put.putWord8 (shift len 16)
  Put.putWord8 (shift len 8)
  Put.putWord8 (shift len 0)

getType :: Get Type
getType = do
  byte <- Get.getWord8
  return $ case byte of
    0x0 -> TData
    0x1 -> THeaders
    0x2 -> TPriority
    0x3 -> TRstStream
    0x4 -> TSettings
    0x5 -> TPushPromise
    0x6 -> TPing
    0x7 -> TGoaway
    0x8 -> TWindowUpdate
    0x9 -> TContinuation
    _   -> TUnknown

putType :: Type -> Put
putType TData         = Put.putWord8 0x0
putType THeaders      = Put.putWord8 0x1
putType TPriority     = Put.putWord8 0x2
putType TRstStream    = Put.putWord8 0x3
putType TSettings     = Put.putWord8 0x4
putType TPushPromise  = Put.putWord8 0x5
putType TPing         = Put.putWord8 0x6
putType TGoaway       = Put.putWord8 0x7
putType TWindowUpdate = Put.putWord8 0x8
putType TContinuation = Put.putWord8 0x9
putType TUnknown      = undefined

getStreamId :: Get StreamId
getStreamId = StreamId . flip Bits.clearBit 31 <$> Get.getWord32be

putStreamId :: StreamId -> Put
putStreamId (StreamId i) = Put.putWord32be (Bits.clearBit i 31)

getPayload :: FrameLength -> FrameFlags -> StreamId -> Type -> ExceptT ErrorCode Get Payload
getPayload len flags sId TSettings = PSettings <$> FSettings.getPayload len flags sId
getPayload len _     _   _         = lift $ PBuffer <$> Get.getLazyByteString (fromIntegral len)

putPayload :: Payload -> Put
putPayload (PSettings settings) = FSettings.putPayload settings
putPayload (PBuffer buffer) = Put.putLazyByteString buffer

get :: ExceptT ErrorCode Get Frame
get = do
  fLength <- lift $ getLength
  fType <- lift $ getType
  fFlags <- lift $ Get.getWord8
  fStreamId <- lift $ getStreamId
  fPayload <- getPayload fLength fFlags fStreamId fType
  return $ Frame { fLength, fType, fFlags, fStreamId, fPayload }

put :: Frame -> Put
put Frame { fLength, fType, fFlags, fStreamId, fPayload } = do
  putLength fLength
  putType fType
  Put.putWord8 fFlags
  putStreamId fStreamId
  putPayload fPayload

readFrame :: IO ByteString -> ExceptT ErrorCode IO Frame
readFrame readBuffer =
  let impl :: Get.Decoder (Either ErrorCode Frame) -> ExceptT ErrorCode IO Frame
      impl (Get.Fail _ _ _)       = Except.throwError ProtocolError
      impl (Get.Partial continue) = do
        buffer <- liftIO readBuffer
        impl (continue (Just (ByteString.toStrict buffer)))
      impl (Get.Done _ _ (Left err))    = Except.throwError err
      impl (Get.Done _ _ (Right frame)) = return frame
  in impl (Get.runGetIncremental (Except.runExceptT Frame.get))

writeFrame :: (ByteString -> IO ()) -> Frame -> IO ()
writeFrame write = write . Put.runPut . put

toString :: Frame -> String
toString Frame { fType, fStreamId, fPayload } =
  let StreamId i = fStreamId in
  show fType ++ "(" ++ show i ++ ")\n" ++
  case fPayload of
    PSettings payload -> FSettings.toString "  " payload
    _ -> ""
