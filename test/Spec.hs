{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Hspec entry point for the Pigeon suite: unit tests plus integration tests
against a real Warp server on an ephemeral port.
-}
module Main (main) where

import Control.Exception.Safe (SomeException, throwIO, try)
import Control.Monad (void)
import Data.Aeson (decode, encode)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.Conduit (runConduitRes, yield, (.|))
import Data.Conduit.Combinators (sinkList)
import Data.Conduit.Zlib (gzip, ungzip)
import Data.Either (isLeft, isRight)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (elemIndex, nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word8)
import Database.SQLite.Simple (Only (..), query_)
import Network.HTTP.Client (responseHeaders)
import Network.HTTP.Types (Header, hContentType, statusCode)
import Servant.API (FromHttpApiData (parseUrlPiece), ToHttpApiData (toUrlPiece))
import System.Directory (
  createDirectory,
  doesDirectoryExist,
  doesFileExist,
  listDirectory,
  removeFile,
 )
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (
  createSymbolicLink,
  fileMode,
  getFileStatus,
  setFileMode,
 )
import System.Posix.Types (FileMode)
import Test.Hspec
import Test.QuickCheck hiding ((.&.))

import Pigeon.API (UploadBody)
import Pigeon.Duration
import Pigeon.Password
import Pigeon.Server.Config (ServerConfig (..))
import Pigeon.Server.Db
import Pigeon.Server.Storage
import Pigeon.Streaming
import Pigeon.Types
import Support

main :: IO ()
main = hspec $ do
  describe "Pigeon.Duration" $ do
    it "parses the documented examples" $ do
      parseDuration "30m" `shouldBe` Right 1800
      parseDuration "12h" `shouldBe` Right 43200
      parseDuration "7d" `shouldBe` Right 604800
      parseDuration "2w" `shouldBe` Right 1209600
      parseDuration "1d12h" `shouldBe` Right 129600
      parseDuration "7D" `shouldBe` Right 604800
    it "rejects invalid durations" $
      mapM_
        (\value -> parseDuration value `shouldSatisfy` isLeft)
        ["", "0", "-1h", "1.5h", "1h ", "h", "1x", "1h2"]
    it "round-trips through a normalized form" $
      property $ \(Positive n :: Positive Int) ->
        let seconds = fromIntegral (n `mod` 1000000 + 1) :: Int64
         in parseDuration (formatDuration seconds) == Right seconds

  describe "filename and content-type sanitisation" $ do
    it "removes path separators and control characters" $ do
      sanitizeFilename "../../etc/passwd" `shouldBe` ".._.._etc_passwd"
      sanitizeFilename "a\r\nb\0c" `shouldBe` "a__b_c"
    it "trims spaces, handles dots, and truncates at a character boundary" $ do
      sanitizeFilename "  report.pdf  " `shouldBe` "report.pdf"
      sanitizeFilename "..." `shouldBe` "file"
      sanitizeFilename "" `shouldBe` "file"
      BS.length (encodeUtf8 (sanitizeFilename (T.replicate 300 "ä"))) `shouldSatisfy` (<= 255)
    it "sanitises content types" $ do
      sanitizeContentType "text/plain" `shouldBe` "text/plain"
      sanitizeContentType "text/plain\r\nX-Evil: yes" `shouldBe` "application/octet-stream"
    it "builds an attachment header with an RFC 5987 filename" $ do
      let header = contentDisposition "sécret<file>.txt"
      header `shouldSatisfy` BS.isInfixOf "attachment"
      header `shouldSatisfy` BS.isInfixOf "filename*=UTF-8''s%C3%A9cret%3Cfile%3E.txt"

  describe "file ids" $ do
    it "matches the pinned Crockford vectors" $ do
      unFileId (encodeFileId (BS.replicate 10 0)) `shouldBe` "0000000000000000"
      unFileId (encodeFileId (BS.replicate 10 0xff)) `shouldBe` "zzzzzzzzzzzzzzzz"
      unFileId (encodeFileId (BS.pack [0 .. 9])) `shouldBe` "000g40r40m30e209"
      unFileId (encodeFileId (BS.replicate 9 0 <> BS.singleton 1)) `shouldBe` "0000000000000001"
    it "round-trips arbitrary ten-byte values" $
      property $ \(bytes :: [Word8]) ->
        let ten = BS.pack (take 10 (bytes ++ repeat 0))
         in decodeCrockford (unFileId (encodeFileId ten))
              === Just (bytesToInteger ten)
    it "generates valid Crockford ids" $ do
      ids <- mapM (const generateFileId) [1 .. 1000 :: Int]
      mapM_ (\fid -> isValidFileId fid `shouldBe` True) ids
    it "does not repeat ids" $ do
      ids <- mapM (const generateFileId) [1 .. 10000 :: Int]
      length (nub ids) `shouldBe` 10000
    it "uses exactly the lowercase Crockford alphabet" $ do
      mapM_
        (\c -> isValidFileId (FileId (T.replicate 16 (T.singleton c))) `shouldBe` True)
        (T.unpack crockfordAlphabet)
      mapM_
        (\c -> isValidFileId (FileId (T.replicate 16 (T.singleton c))) `shouldBe` False)
        (T.unpack "ilouILOU-/ ._~")
    it "rejects malformed ids" $
      mapM_
        (\value -> mkFileId value `shouldSatisfy` isLeft)
        [ "short",
          "ABCDEFGHIJKLMNOP",
          "000000000000000i",
          "0000000000000000 ",
          "",
          T.replicate 15 "0",
          T.replicate 17 "0",
          T.replicate 16 "o",
          T.replicate 16 "l",
          T.replicate 16 "u",
          T.replicate 16 "I",
          T.replicate 16 "O",
          T.replicate 16 "L",
          T.replicate 16 "U",
          "000000000000000-",
          "000000000000000\NUL"
        ]
    it "round-trips ids through JSON and URL encodings" $ do
      let fid = FileId "000g40r40m30e209"
      decode (encode fid) `shouldBe` Just fid
      parseUrlPiece (toUrlPiece fid) `shouldBe` Right fid

  describe "PBKDF2 password hashing" $ do
    let fixtureHash :: Text
        fixtureHash =
          "sha512:25000:YWJjZGVmZ2hpamtsbW5vcA==:JRElYYrOMe9OIV4LDxaLTgO9ho8fFBVofXoQcdngi7AcuH6Amvmlj2B0y6y1UtQciXXBepSCS+rpy8/vDDQvoA=="
        fixture = hashPasswordWithIterationsAndSalt 25000 "abcdefghijklmnop" "foobar"
    it "reproduces the package fixture" $
      unStoredPasswordHash fixture `shouldBe` fixtureHash
    it "verifies the fixture and rejects a wrong password" $ do
      verifyPassword "foobar" fixture `shouldBe` True
      verifyPassword "barfoo" fixture `shouldBe` False
    it "round-trips the stored text and rejects malformed values" $ do
      parseStoredPasswordHash fixtureHash `shouldSatisfy` isRight
      mapM_
        (\value -> parseStoredPasswordHash value `shouldSatisfy` isLeft)
        [ "md5:25000:YWJj:YWJj",
          "sha512:notanumber:YWJj:YWJj",
          "sha512:25000:bad:bad",
          "sha512:100000001:YWJjZGVmZ2hpamtsbW5vcA==:JRElYYrOMe9OIV4LDxaLTgO9ho8fFBVofXoQcdngi7AcuH6Amvmlj2B0y6y1UtQciXXBepSCS+rpy8/vDDQvoA=="
        ]
    it "accepts long and Unicode passwords and keeps them byte-exact" $ do
      let long = T.replicate 200 "a"
          unicode = "päss"
      h1 <- hashPassword 100000 long
      verifyPassword long h1 `shouldBe` True
      h2 <- hashPassword 100000 unicode
      verifyPassword unicode h2 `shouldBe` True
      verifyPassword "pass" h2 `shouldBe` False

  describe "password limits" $ do
    it "accepts 1 to 1024 UTF-8 bytes and rejects the rest" $ do
      validatePassword "a" `shouldBe` Right ()
      validatePassword (T.replicate 1024 "a") `shouldBe` Right ()
      validatePassword "" `shouldSatisfy` isLeft
      validatePassword (T.replicate 1025 "a") `shouldSatisfy` isLeft
    it "counts UTF-8 bytes, not characters" $ do
      validatePassword (T.replicate 512 "ä") `shouldBe` Right ()
      validatePassword (T.replicate 513 "ä") `shouldSatisfy` isLeft

  describe "Accept-Encoding" $ do
    it "negotiates gzip, identity, and not-acceptable" $ do
      parseAcceptEncoding "gzip" `shouldBe` AcceptGzip
      parseAcceptEncoding "identity" `shouldBe` AcceptIdentity
      parseAcceptEncoding "" `shouldBe` AcceptIdentity
      parseAcceptEncoding "gzip;q=0" `shouldBe` AcceptIdentity
      parseAcceptEncoding "gzip;q=0, identity;q=0" `shouldBe` NotAcceptable
      parseAcceptEncoding "*;q=0.5" `shouldBe` AcceptGzip
      parseAcceptEncoding "br, gzip" `shouldBe` AcceptGzip
      parseAcceptEncoding "br" `shouldBe` AcceptIdentity
      parseAcceptEncoding "gzip;q=oops" `shouldBe` AcceptIdentity

  describe "chunked file source" $ do
    it "reads a handle in the requested chunk size and preserves bytes" $ withTempDataDir $ \dir -> do
      let path = dir </> "chunks.bin"
          payload = BS.replicate (300 * 1024) 7
          size = 128 * 1024
      BS.writeFile path payload
      chunks <-
        withBinaryFile path ReadMode $ \handle ->
          runConduitRes (sourceHandleChunked size handle .| sinkList)
      map BS.length chunks `shouldBe` [size, size, BS.length payload - 2 * size]
      BS.concat chunks `shouldBe` payload
    it "yields no chunks for an empty file" $ withTempDataDir $ \dir -> do
      let path = dir </> "empty.bin"
      BS.writeFile path BS.empty
      chunks <-
        withBinaryFile path ReadMode $ \handle ->
          runConduitRes (sourceHandleChunked (128 * 1024) handle .| sinkList)
      chunks `shouldBe` []

  describe "JSON" $ do
    it "serializes FileInfo with the documented field names" $ do
      let now = epochToUtc 1761955200
          info =
            FileInfo
              { fiId = FileId "7q3m9x2k4v8p1c6d",
                fiFilename = "report.pdf",
                fiSize = 123,
                fiContentType = "application/pdf",
                fiCreatedAt = now,
                fiExpiresAt = addUTCTime 3600 now,
                fiHasPassword = True,
                fiUrl = "https://files.example.com/f/7q3m9x2k4v8p1c6d"
              }
      decode (encode info) `shouldBe` Just info
    it "serializes health and error envelopes" $ do
      encode (Health "ok" "0.1.0.0") `shouldBe` "{\"status\":\"ok\",\"version\":\"0.1.0.0\"}"
      encode (ApiErrorEnvelope (ApiError "invalid_request" "bad"))
        `shouldBe` "{\"error\":{\"code\":\"invalid_request\",\"message\":\"bad\"}}"

  describe "storage" $ do
    it "applies SQLite pragmas and migrates idempotently" $ withTempDataDir $ \dir -> do
      db <- openDb (dir </> "pigeon.db")
      migrate db
      migrate db
      mode <- withConn db $ \c -> query_ c "PRAGMA journal_mode" :: IO [Only Text]
      sync <- withConn db $ \c -> query_ c "PRAGMA synchronous" :: IO [Only Int]
      version <- withConn db $ \c -> query_ c "PRAGMA user_version" :: IO [Only Int]
      mode `shouldBe` [Only "delete"]
      sync `shouldBe` [Only 2]
      version `shouldBe` [Only 1]
      closeDb db
    it "stores identity uploads as gzip and round-trips them" $ withTempDataDir $ \dir -> do
      storage <- initStorage defaultStorageHooks dir
      db <- openDb (dir </> "pigeon.db")
      migrate db
      now <- getCurrentTime
      let payload = BS.concat (replicate 100 "random-ish bytes")
          request =
            StoreRequest
              { srFilename = "data.bin",
                srContentType = "application/octet-stream",
                srExpiresAt = addUTCTime 3600 now,
                srPasswordHash = Nothing,
                srContentEncoding = Nothing,
                srMaxUploadSize = 0,
                srBody = yieldBody payload
              }
      stored <- storeUpload storage db request >>= either (fail . show) pure
      sfSize stored `shouldBe` fromIntegral (BS.length payload)
      blob <- BS.readFile (blobPath storage (sfId stored))
      raw <- runConduitRes (yield blob .| ungzip .| sinkList)
      BS.concat raw `shouldBe` payload
      doesFileExist (dir </> "pigeon.db-wal") `shouldReturn` False
      closeDb db
    it "stores gzip uploads as received and reports the original size" $ withTempDataDir $ \dir -> do
      storage <- initStorage defaultStorageHooks dir
      db <- openDb (dir </> "pigeon.db")
      migrate db
      now <- getCurrentTime
      let payload = BS.concat (replicate 200 "compressible payload ")
      encoded <- gzipBytes payload
      stored <-
        storeUpload storage db (storeRequest now (Just "gzip") encoded)
          >>= either (fail . show) pure
      sfSize stored `shouldBe` fromIntegral (BS.length payload)
      sfStoredSize stored `shouldBe` fromIntegral (BS.length encoded)
      blob <- BS.readFile (blobPath storage (sfId stored))
      blob `shouldBe` encoded
      closeDb db
    it "stores every received gzip byte even after the stream ends" $ withTempDataDir $ \dir -> do
      storage <- initStorage defaultStorageHooks dir
      db <- openDb (dir </> "pigeon.db")
      migrate db
      now <- getCurrentTime
      let payload = "payload"
      compressed <- gzipBytes payload
      let received = compressed <> "trailing bytes"
      stored <-
        storeUpload storage db (storeRequest now (Just "gzip") received)
          >>= either (fail . show) pure
      sfSize stored `shouldBe` fromIntegral (BS.length payload)
      blob <- BS.readFile (blobPath storage (sfId stored))
      blob `shouldBe` received
      closeDb db
    it "rejects an invalid gzip upload and removes the temp file" $ withTempDataDir $ \dir -> do
      storage <- initStorage defaultStorageHooks dir
      db <- openDb (dir </> "pigeon.db")
      migrate db
      now <- getCurrentTime
      let request :: StoreRequest
          request =
            StoreRequest
              { srFilename = "bad.gz",
                srContentType = "application/octet-stream",
                srExpiresAt = addUTCTime 3600 now,
                srPasswordHash = Nothing,
                srContentEncoding = Just "gzip",
                srMaxUploadSize = 0,
                srBody = yieldBody "not gzip"
              }
      result <- storeUpload storage db request
      result `shouldSatisfy` isLeft
      listLiveFiles db now `shouldReturn` []
      listBlobIds storage `shouldReturn` []
      listTempFiles storage `shouldReturn` []
      closeDb db
    it "enforces the upload size limit for identity uploads" $ withTempDataDir $ \dir -> do
      storage <- initStorage defaultStorageHooks dir
      db <- openDb (dir </> "pigeon.db")
      migrate db
      now <- getCurrentTime
      let request :: StoreRequest
          request =
            StoreRequest
              { srFilename = "big",
                srContentType = "application/octet-stream",
                srExpiresAt = addUTCTime 3600 now,
                srPasswordHash = Nothing,
                srContentEncoding = Nothing,
                srMaxUploadSize = 4,
                srBody = yieldBody "12345"
              }
      result <- storeUpload storage db request
      result `shouldBe` Left StorageTooLarge
      closeDb db
    it "enforces the upload size limit on decompressed gzip bytes" $ withTempDataDir $ \dir -> do
      storage <- initStorage defaultStorageHooks dir
      db <- openDb (dir </> "pigeon.db")
      migrate db
      now <- getCurrentTime
      let payload = B8.replicate 10000 'a'
          limit = 4096 :: Int64
      encoded <- gzipBytes payload
      BS.length encoded `shouldSatisfy` (< fromIntegral limit)
      let request :: StoreRequest
          request =
            StoreRequest
              { srFilename = "bomb.gz",
                srContentType = "application/octet-stream",
                srExpiresAt = addUTCTime 3600 now,
                srPasswordHash = Nothing,
                srContentEncoding = Just "gzip",
                srMaxUploadSize = limit,
                srBody = yieldBody encoded
              }
      result <- storeUpload storage db request
      result `shouldBe` Left StorageTooLarge
      listLiveFiles db now `shouldReturn` []
      listBlobIds storage `shouldReturn` []
      listTempFiles storage `shouldReturn` []
      closeDb db
    it "fails the upload and removes state when the temp file cannot be fsynced" $
      withTempDataDir $ \dir -> do
        messages <- newIORef []
        let hooks :: StorageHooks
            hooks =
              defaultStorageHooks
                { shSyncFile = \_ -> throwIO (userError "fsync failed"),
                  shError = recordMessage messages
                }
        storage <- initStorage hooks dir
        db <- openDb (dir </> "pigeon.db")
        migrate db
        now <- getCurrentTime
        result <- storeUpload storage db (storeRequest now Nothing "payload")
        result `shouldSatisfy` isLeft
        listLiveFiles db now `shouldReturn` []
        listDirectory (dir </> "files") `shouldReturn` []
        listTempFiles storage `shouldReturn` []
        recorded <- readIORef messages
        recorded `shouldSatisfy` any (T.isInfixOf "fsync failed")
        closeDb db
    it "fails the upload and removes the blob when directory fsync fails" $
      withTempDataDir $ \dir -> do
        let hooks :: StorageHooks
            hooks =
              defaultStorageHooks
                { shSyncDir = \_ -> throwIO (userError "directory fsync failed")
                }
        storage <- initStorage hooks dir
        db <- openDb (dir </> "pigeon.db")
        migrate db
        now <- getCurrentTime
        result <- storeUpload storage db (storeRequest now Nothing "payload")
        result `shouldSatisfy` isLeft
        listLiveFiles db now `shouldReturn` []
        listDirectory (dir </> "files") `shouldReturn` []
        listTempFiles storage `shouldReturn` []
        closeDb db
    it "continues and warns once when directory fsync is unsupported" $
      withTempDataDir $ \dir -> do
        warnings <- newIORef []
        let hooks :: StorageHooks
            hooks =
              defaultStorageHooks
                { shSyncDir = \_ -> pure DirSyncUnsupported,
                  shWarn = recordMessage warnings
                }
        storage <- initStorage hooks dir
        db <- openDb (dir </> "pigeon.db")
        migrate db
        now <- getCurrentTime
        first <- storeUpload storage db (storeRequest now Nothing "one")
        second <- storeUpload storage db (storeRequest now Nothing "two")
        first `shouldSatisfy` isRight
        second `shouldSatisfy` isRight
        length <$> listDirectory (dir </> "files") `shouldReturn` 2
        length <$> readIORef warnings `shouldReturn` 1
        closeDb db
    it "logs an orphan and inserts no row when post-rename cleanup fails" $
      withTempDataDir $ \dir -> do
        warnings <- newIORef []
        let hooks :: StorageHooks
            hooks =
              defaultStorageHooks
                { shSyncDir = \_ -> throwIO (userError "directory fsync failed"),
                  shRemoveBlob = \_ -> throwIO (userError "cannot remove"),
                  shWarn = recordMessage warnings
                }
        storage <- initStorage hooks dir
        db <- openDb (dir </> "pigeon.db")
        migrate db
        now <- getCurrentTime
        result <- storeUpload storage db (storeRequest now Nothing "payload")
        result `shouldSatisfy` isLeft
        listLiveFiles db now `shouldReturn` []
        length <$> listDirectory (dir </> "files") `shouldReturn` 1
        recorded <- readIORef warnings
        recorded `shouldSatisfy` any (T.isInfixOf "orphan")
        closeDb db

  describe "path safety" $ do
    it "creates private storage directories" $ withTempDataDir $ \dir -> do
      let root = dir </> "nested" </> "data"
      storage <- initStorage defaultStorageHooks root
      stRoot storage `shouldBe` root
      modeOf root `shouldReturn` 0o700
      modeOf (stFilesDir storage) `shouldReturn` 0o700
      modeOf (stTmpDir storage) `shouldReturn` 0o700
    it "rejects a symlinked data directory without changing its target" $
      withTempDataDir $ \dir -> do
        let target = dir </> "target"
            link = dir </> "data-link"
        createDirectory target
        setFileMode target 0o755
        createSymbolicLink target link
        expectPathFailure (initStorage defaultStorageHooks link)
        modeOf target `shouldReturn` 0o755
        doesDirectoryExist (target </> "files") `shouldReturn` False
    it "rejects symlinked files and tmp directories" $
      withTempDataDir $ \dir -> do
        let target = dir </> "target"
        createDirectory target
        setFileMode target 0o755
        createSymbolicLink target (dir </> "files")
        expectPathFailure (initStorage defaultStorageHooks dir)
        modeOf target `shouldReturn` 0o755
        removeFile (dir </> "files")
        createSymbolicLink target (dir </> "tmp")
        expectPathFailure (initStorage defaultStorageHooks dir)
        modeOf target `shouldReturn` 0o755
    it "creates the database with mode 0600 and tightens existing files" $
      withTempDataDir $ \dir -> do
        let dbPath = dir </> "pigeon.db"
        db <- openDb dbPath
        closeDb db
        modeOf dbPath `shouldReturn` 0o600
        setFileMode dbPath 0o644
        db2 <- openDb dbPath
        closeDb db2
        modeOf dbPath `shouldReturn` 0o600
    it "rejects a symlinked database file without touching its target" $
      withTempDataDir $ \dir -> do
        let target = dir </> "target.db"
            link = dir </> "pigeon.db"
        BS.writeFile target "not a database"
        setFileMode target 0o640
        createSymbolicLink target link
        expectPathFailure (openDb link)
        modeOf target `shouldReturn` 0o640
        BS.readFile target `shouldReturn` "not a database"
    it "rejects a symlinked database parent" $
      withTempDataDir $ \dir -> do
        let target = dir </> "outside"
            link = dir </> "dbdir"
        createDirectory target
        createSymbolicLink target link
        expectPathFailure (openDb (link </> "pigeon.db"))
        doesFileExist (target </> "pigeon.db") `shouldReturn` False
    it "rejects a database parent writable by other users" $
      withTempDataDir $ \dir -> do
        let parent = dir </> "insecure"
        createDirectory parent
        setFileMode parent 0o777
        expectPathFailure (openDb (parent </> "pigeon.db"))

  describe "HTTP integration" $ do
    it "serves health without authentication" $ withTestServer $ \_ port -> do
      response <- requestWith port "/healthz" "GET" [] BS.empty
      statusCode (statusOf response) `shouldBe` 200
      bodyOf response `shouldBe` "{\"status\":\"ok\",\"version\":\"0.1.0.0\"}"
    it "rejects an unauthenticated upload" $ withTestServer $ \_ port -> do
      response <-
        requestWith
          port
          "/api/v1/files?filename=x"
          "POST"
          [("Content-Type", "application/octet-stream")]
          "x"
      statusCode (statusOf response) `shouldBe` 401
    it "lists an empty server as [] in JSON mode" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      files <- listFiles client
      files `shouldBe` []
    it "uploads, lists, downloads, and deletes" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      info <- uploadRaw client "hello.txt" "hello pigeon"
      fiFilename info `shouldBe` "hello.txt"
      listed <- listFiles client
      map fiId listed `shouldContain` [fiId info]
      identityResponse <- download port (fiId info) [("Accept-Encoding", "identity")]
      statusCode (statusOf identityResponse) `shouldBe` 200
      bodyOf identityResponse `shouldBe` "hello pigeon"
      lookup "Content-Disposition" (responseHeaders identityResponse)
        `shouldSatisfy` maybe False (BS.isInfixOf "attachment")
      gzipResponse <- download port (fiId info) [("Accept-Encoding", "gzip")]
      lookup "Content-Encoding" (responseHeaders gzipResponse) `shouldBe` Just "gzip"
      deleteFile client (fiId info)
      gone <- download port (fiId info) []
      statusCode (statusOf gone) `shouldBe` 404
    it "supports HEAD, ignores Range, and returns 404 for unknown ids" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      info <- uploadRaw client "head.txt" "head body"
      headResponse <- requestWith port ("/f/" <> T.unpack (unFileId (fiId info))) "HEAD" [] BS.empty
      statusCode (statusOf headResponse) `shouldBe` 200
      bodyOf headResponse `shouldBe` ""
      lookup "Content-Disposition" (responseHeaders headResponse)
        `shouldSatisfy` maybe False (BS.isInfixOf "attachment")
      ranged <-
        requestWith port ("/f/" <> T.unpack (unFileId (fiId info))) "GET" [("Range", "bytes=0-2")] BS.empty
      statusCode (statusOf ranged) `shouldBe` 200
      bodyOf ranged `shouldBe` "head body"
      missing <- download port (FileId "0000000000000000") []
      statusCode (statusOf missing) `shouldBe` 404
    it "uploads gzip bodies and reports the original size" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      info <- uploadGzip client "hello.txt" "hello gzip"
      fiSize info `shouldBe` 10
      response <- download port (fiId info) [("Accept-Encoding", "identity")]
      bodyOf response `shouldBe` "hello gzip"
    it "serves the password form and enforces the password" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      info <- uploadWithPassword client "secret.txt" "hunter2" "top secret"
      form <- download port (fiId info) []
      statusCode (statusOf form) `shouldBe` 200
      lookup hContentType (responseHeaders form)
        `shouldSatisfy` maybe False (BS.isPrefixOf "text/html")
      LBS.toStrict (bodyOf form) `shouldSatisfy` not . BS.isInfixOf "top secret"
      wrong <- postForm port (fiId info) "password=nope"
      statusCode (statusOf wrong) `shouldBe` 401
      LBS.toStrict (bodyOf wrong) `shouldSatisfy` BS.isInfixOf "Incorrect password"
      correct <- postForm port (fiId info) "password=hunter2"
      statusCode (statusOf correct) `shouldBe` 200
      bodyOf correct `shouldBe` "top secret"
      missing <- postForm port (fiId info) "x=1"
      statusCode (statusOf missing) `shouldBe` 401
      duplicate <- postForm port (fiId info) "password=hunter2&password=hunter2"
      statusCode (statusOf duplicate) `shouldBe` 401
      large <- postForm port (fiId info) (B8.replicate 9000 'x')
      statusCode (statusOf large) `shouldBe` 413
      wrongType <-
        requestWith
          port
          ("/f/" <> T.unpack (unFileId (fiId info)))
          "POST"
          [("Content-Type", "text/plain")]
          "password=hunter2"
      statusCode (statusOf wrongType) `shouldBe` 415
    it "returns 405 for unsupported methods and serves robots.txt" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      info <- uploadRaw client "x.txt" "x"
      response <- requestWith port ("/f/" <> T.unpack (unFileId (fiId info))) "PUT" [] BS.empty
      statusCode (statusOf response) `shouldBe` 405
      lookup "Allow" (responseHeaders response) `shouldBe` Just "GET, HEAD, POST"
      robots <- requestWith port "/robots.txt" "GET" [] BS.empty
      bodyOf robots `shouldBe` "User-agent: *\nDisallow: /\n"
    it "rejects malformed ids as 400 on the API and 404 on the web route" $ withTestServer $ \_ port -> do
      api <-
        requestWith
          port
          "/api/v1/files/000000000000000i"
          "DELETE"
          [("Authorization", encodeUtf8 authHeader)]
          BS.empty
      statusCode (statusOf api) `shouldBe` 400
      LBS.toStrict (bodyOf api) `shouldSatisfy` BS.isInfixOf "invalid_request"
      web <- requestWith port "/f/000000000000000i" "GET" [] BS.empty
      statusCode (statusOf web) `shouldBe` 404
    it "refuses path traversal in a file id" $ withTestServer $ \_ port -> do
      response <-
        requestWith
          port
          "/api/v1/files/%2E%2E%2F%2E%2E%2F%2E%2E%2Fetc%2Fpasswd"
          "DELETE"
          [("Authorization", encodeUtf8 authHeader)]
          BS.empty
      statusCode (statusOf response) `shouldBe` 400
    it "rejects a password over 1024 UTF-8 bytes with 400" $ withTestServer $ \_ port -> do
      let tooLong :: [Header]
          tooLong =
            [ ("Authorization", encodeUtf8 authHeader),
              ("X-Pigeon-Password", encodeUtf8 (encodePassword (T.replicate 1025 "a")))
            ]
          atLimit :: [Header]
          atLimit =
            [ ("Authorization", encodeUtf8 authHeader),
              ("X-Pigeon-Password", encodeUtf8 (encodePassword (T.replicate 1024 "a")))
            ]
      rejected <- requestWith port "/api/v1/files?filename=x" "POST" tooLong "x"
      statusCode (statusOf rejected) `shouldBe` 400
      accepted <- requestWith port "/api/v1/files?filename=x" "POST" atLimit "x"
      statusCode (statusOf accepted) `shouldBe` 201
    it "rejects an oversized form password with 401" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      info <- uploadWithPassword client "big.txt" "hunter2" "x"
      response <- postForm port (fiId info) ("password=" <> B8.replicate 1025 'a')
      statusCode (statusOf response) `shouldBe` 401
    it "applies the default expiry when expires_in is omitted" $ withTestServer $ \cfg port -> do
      client <- testClientEnv port
      info <- uploadRaw client "default.txt" "x"
      let lifetime = realToFrac (diffUTCTime (fiExpiresAt info) (fiCreatedAt info)) :: Double
      lifetime `shouldSatisfy` (\d -> abs (d - fromIntegral (scDefaultExpiry cfg)) < 5)
    it "returns 400 for an expiry above max_expiry" $ withTestServer $ \_ port -> do
      client <- testClientEnv port
      result <- uploadWithExpiresEither client "x" (8 * 86400)
      case result of
        Left status -> status `shouldBe` 400
        Right _ -> expectationFailure "expected 400"

expectPathFailure :: IO a -> IO ()
expectPathFailure action = do
  result <- try (void action) :: IO (Either SomeException ())
  result `shouldSatisfy` isLeft

modeOf :: FilePath -> IO FileMode
modeOf path = (\status -> fileMode status .&. 0o777) <$> getFileStatus path

yieldBody :: BS.ByteString -> UploadBody
yieldBody = yield

-- | Compress bytes into a single gzip payload.
gzipBytes :: BS.ByteString -> IO BS.ByteString
gzipBytes bytes = BS.concat <$> runConduitRes (yield bytes .| gzip .| sinkList)

-- | A minimal request for storage-level upload tests.
storeRequest :: UTCTime -> Maybe BS.ByteString -> BS.ByteString -> StoreRequest
storeRequest now encoding body =
  StoreRequest
    { srFilename = "data.bin",
      srContentType = "application/octet-stream",
      srExpiresAt = addUTCTime 3600 now,
      srPasswordHash = Nothing,
      srContentEncoding = encoding,
      srMaxUploadSize = 0,
      srBody = yieldBody body
    }

-- | Record a log message in order of arrival.
recordMessage :: IORef [Text] -> Text -> IO ()
recordMessage ref message =
  atomicModifyIORef' ref (\messages -> (message : messages, ()))

{- | The canonical lowercase Crockford alphabet, restated independently of the
production constant so the tests pin the format rather than mirror it.
-}
crockfordAlphabet :: Text
crockfordAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"

-- | Test-local Crockford decoder, used only to verify 'encodeFileId'.
decodeCrockford :: Text -> Maybe Integer
decodeCrockford = T.foldl' step (Just 0)
 where
  step :: Maybe Integer -> Char -> Maybe Integer
  step Nothing _ = Nothing
  step (Just acc) c =
    (\digit -> acc * 32 + fromIntegral digit)
      <$> elemIndex c (T.unpack crockfordAlphabet)

bytesToInteger :: BS.ByteString -> Integer
bytesToInteger = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) 0
