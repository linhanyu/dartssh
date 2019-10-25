// Copyright 2019 dartssh developers
// Use of this source code is governed by a MIT-style license that can be found in the LICENSE file.

import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import "package:pointycastle/api.dart";
import "package:pointycastle/digests/sha256.dart";
import 'package:pointycastle/macs/hmac.dart';
import 'package:validators/sanitizers.dart';

import 'package:dartssh/protocol.dart';
import 'package:dartssh/serializable.dart';
import 'package:dartssh/socket.dart';
import 'package:dartssh/socket_html.dart'
    if (dart.library.io) 'package:dartssh/socket_io.dart';
import 'package:dartssh/ssh.dart';

typedef VoidCallback = void Function();
typedef StringCallback = void Function(String);
typedef StringFunction = String Function();
typedef Uint8ListFunction = Uint8List Function();
typedef IdentityFunction = Identity Function();
typedef FingerprintCallback = bool Function(int, Uint8List);
typedef ChannelCallback = void Function(Channel, Uint8List);
typedef RemoteForwardCallback = void Function(
    Channel, String, int, String, int);

class Forward {
  int port, targetPort;
  String targetHost;
}

class Identity {
  RSAKey rsa;
  /*ECPair ec;
  Ed25519Pair ed25519;*/
}

class Channel {
  int localId, remoteId, windowC = 0, windowS = 0;
  bool opened = true, agentChannel = false, sentEof = false, sentClose = false;
  Uint8List buf;
  ChannelCallback cb;
  Channel([this.localId = 0, this.remoteId = 0]);
}

class SSHClientState {
  static const int INIT = 0,
      FIRST_KEXINIT = 1,
      FIRST_KEXREPLY = 2,
      FIRST_NEWKEYS = 3,
      KEXINIT = 4,
      KEXREPLY = 5,
      NEWKEYS = 6;
}

class SSHClient {
  String hostport, user, termvar, startupCommand;
  bool compress, agentForwarding, closeOnDisconnect, backgroundServices;
  List<Forward> forwardLocal, forwardRemote;
  StringCallback response, print, debugPrint, tracePrint;
  FingerprintCallback hostFingerprint;
  RemoteForwardCallback remoteForward;
  Uint8ListFunction getPassword;
  IdentityFunction loadIdentity;
  VoidCallback success;
  Random random;

  String verC = 'SSH-2.0-dartssh_1.0', verS, login;

  num serverVersion = 0;

  int state = 0,
      padding = 0,
      packetId = 0,
      packetLen = 0,
      packetMacLen = 0,
      hostkeyType = 0,
      kexMethod = 0,
      macPrefixC2s = 0,
      macPrefixS2c = 0,
      macLenC = 0,
      macLenS = 0,
      macIdC2s = 0,
      macIdS2c = 0,
      cipherIdC2s = 0,
      cipherIdS2c = 0,
      compressIdC2s = 0,
      compressIdS2c = 0,
      encryptBlockSize = 0,
      decryptBlockSize = 0,
      sequenceNumberC2s = 0,
      sequenceNumberS2c = 0,
      nextChannelId = 1,
      loginPrompts = 0,
      passwordPrompts = 0,
      userauthFail = 0;

  bool guessedC = false,
      guessedS = false,
      guessedRightC = false,
      guessedRightS = false,
      acceptedHostkey = false,
      loadedPw = false,
      wrotePw = false;

  SocketInterface socket;
  QueueBuffer readBuffer = QueueBuffer(Uint8List(0));
  SerializableInput packetS;
  Uint8List kexInitC,
      kexInitS,
      decryptBuf,
      hText,
      sessionId,
      integrityC2s,
      integrityS2c,
      pw;

  DiffieHellman dh = DiffieHellman();
  EllipticCurveDiffieHellman ecdh = EllipticCurveDiffieHellman();
  X25519DiffieHellman x25519dh = X25519DiffieHellman();
  Digest kexHash;
  BigInt K;
  BlockCipher encrypt, decrypt;
  HMac macAlgoC2s, macAlgoS2c;
  Identity identity;
  Channel sessionChannel;
  HashMap<int, Channel> channels = HashMap<int, Channel>();

  int initialWindowSize = 1048576,
      maxPacketSize = 32768,
      termWidth = 80,
      termHeight = 25;
  ZLibDecoder zreader;
  ZLibEncoder zwriter;
  HashMap<int, Forward> forwardingRemote;

  SSHClient(
      {this.hostport,
      this.user,
      this.termvar,
      this.startupCommand,
      this.compress = false,
      this.agentForwarding = false,
      this.closeOnDisconnect,
      this.backgroundServices,
      this.forwardLocal,
      this.forwardRemote,
      this.response,
      this.print,
      this.debugPrint,
      this.tracePrint,
      this.success,
      this.hostFingerprint,
      this.loadIdentity,
      this.getPassword,
      this.socket,
      this.random}) {
    socket ??= SocketImpl();
    random ??= Random.secure();
    if (debugPrint != null) {
      debugPrint('Connecting to $hostport');
    }
    socket.connect(
        hostport, onConnected, (error) => disconnect('connect error'));
  }

  void disconnect(String reason) {
    socket.close();
    if (debugPrint != null) debugPrint('disconnected: ' + reason);
  }

  void onConnected(dynamic x) {
    socket.handleError((error) => disconnect('socket error'));
    socket.handleDone((v) => disconnect('socket done'));
    socket.listen(handleRead);
    handleConnected();
  }

  void handleConnected() {
    if (debugPrint != null) debugPrint('handleConnected');
    if (state != SSHClientState.INIT) throw FormatException('$state');
    socket.send(verC + '\r\n');
    sendKeyExchangeInit(false);
  }

  void sendKeyExchangeInit(bool guess) {
    String keyPref = Key.preferenceCsv(),
        kexPref = KEX.preferenceCsv(),
        cipherPref = Cipher.preferenceCsv(),
        macPref = MAC.preferenceCsv(),
        compressPref = Compression.preferenceCsv(compress ? 0 : 1);

    sequenceNumberC2s++;
    kexInitC = MSG_KEXINIT
        .create(randBytes(random, 16), kexPref, keyPref, cipherPref, cipherPref,
            macPref, macPref, compressPref, compressPref, '', '', guess)
        .toBytes(null, random, 8);

    if (debugPrint != null) {
      debugPrint(
          '$hostport wrote KEXINIT_C { kex=$kexPref key=$keyPref, cipher=$cipherPref, mac=$macPref, compress=$compressPref }');
    }
    socket.sendRaw(kexInitC);
  }

  void handleRead(Uint8List dataChunk) {
    readBuffer.add(dataChunk);

    if (state == SSHClientState.INIT) {
      handleInitialState();
      if (state == SSHClientState.INIT) return;
    }

    while (true) {
      bool encrypted = state > SSHClientState.FIRST_NEWKEYS;

      if (packetLen == 0) {
        packetMacLen =
            macLenS != 0 ? (macPrefixS2c != 0 ? macPrefixS2c : macLenS) : 0;
        if (readBuffer.data.length < BinaryPacket.headerSize ||
            (encrypted && readBuffer.data.length < decryptBlockSize)) {
          return;
        }
        if (encrypted) {
          decryptBuf =
              readCipher(viewUint8List(readBuffer.data, 0, decryptBlockSize));
        }
        BinaryPacket binaryPacket =
            BinaryPacket(encrypted ? decryptBuf : readBuffer.data);
        packetLen = 4 + binaryPacket.length + packetMacLen;
        padding = binaryPacket.padding;
      }
      if (readBuffer.data.length < packetLen) return;
      if (encrypted) {
        decryptBuf = appendUint8List(
            decryptBuf,
            readCipher(viewUint8List(readBuffer.data, decryptBlockSize,
                packetLen - decryptBlockSize - packetMacLen)));
      }
      sequenceNumberS2c++;
      if (encrypted && packetMacLen != 0) {
        Uint8List mac = computeMAC(
            MAC.mac(macIdS2c),
            macLenS,
            viewUint8List(decryptBuf, 0, packetLen - packetMacLen),
            sequenceNumberS2c - 1,
            integrityS2c,
            macPrefixS2c);
        if (!equalUint8List(
            mac,
            viewUint8List(
                readBuffer.data, packetLen - packetMacLen, packetMacLen))) {
          throw FormatException('$hostport: verify MAC failed');
        }
      }

      Uint8List packet = encrypted ? decryptBuf : readBuffer.data;
      if (zreader != null) {
        packetS = SerializableInput(zreader.convert(viewUint8List(
            packet,
            BinaryPacket.headerSize,
            BinaryPacket.headerSize - packetMacLen - padding)));
      } else {
        packetS = SerializableInput(viewUint8List(
            packet,
            BinaryPacket.headerSize,
            packetLen - BinaryPacket.headerSize - packetMacLen - padding));
      }

      handlePacket(packet);
      readBuffer.flush(packetLen);
      packetLen = 0;
    }
  }

  /// Protocol Version Exchange
  void handleInitialState() {
    int processed = 0, newlineIndex;
    while ((newlineIndex =
            readBuffer.data.indexOf('\n'.codeUnits[0], processed)) !=
        -1) {
      String line = String.fromCharCodes(viewUint8List(
              readBuffer.data, processed, newlineIndex - processed))
          .trim();
      if (tracePrint != null) tracePrint('$hostport: SSH_INIT: $line');
      processed = newlineIndex + 1;
      if (line.startsWith('SSH-')) {
        verS = line;
        serverVersion = toFloat(line.substring(4));
        state++;
        break;
      }
    }
    readBuffer.flush(processed);
  }

  void handlePacket(Uint8List packet) {
    packetId = packetS.getUint8();
    switch (packetId) {
      case MSG_KEXINIT.ID:
        state = state == SSHClientState.FIRST_KEXINIT
            ? SSHClientState.FIRST_KEXREPLY
            : SSHClientState.KEXREPLY;
        handleMSG_KEXINIT(MSG_KEXINIT()..deserialize(packetS), packet);
        break;

      case MSG_KEXDH_REPLY.ID:
      case MSG_KEX_DH_GEX_REPLY.ID:
        handleMSG_KEXDH_REPLY(packetId, packet);
        break;

      case MSG_NEWKEYS.ID:
        handleMSG_NEWKEYS();
        break;

      case MSG_SERVICE_ACCEPT.ID:
        handleMSG_SERVICE_ACCEPT();
        break;

      case MSG_USERAUTH_FAILURE.ID:
        handleMSG_USERAUTH_FAILURE(
            MSG_USERAUTH_FAILURE()..deserialize(packetS));
        break;

      case MSG_USERAUTH_SUCCESS.ID:
        handleMSG_USERAUTH_SUCCESS();
        break;

      case MSG_GLOBAL_REQUEST.ID:
        handleMSG_GLOBAL_REQUEST(MSG_GLOBAL_REQUEST()..deserialize(packetS));
        break;

      default:
        if (print != null) {
          print('$hostport: unknown packet number: $packetId, len $packetLen');
        }
        break;
    }
  }

  void handleMSG_KEXINIT(MSG_KEXINIT msg, Uint8List packet) {
    if (tracePrint != null) tracePrint('$hostport: MSG_KEXINIT $msg');

    guessedS = msg.firstKexPacketFollows;
    kexInitS = packet.sublist(0, packetLen - packetMacLen);

    if (0 == (kexMethod = KEX.preferenceIntersect(msg.kexAlgorithms))) {
      throw FormatException('$hostport: negotiate kex');
    } else if (0 ==
        (hostkeyType = Key.preferenceIntersect(msg.serverHostKeyAlgorithms))) {
      throw FormatException('$hostport: negotiate hostkey');
    } else if (0 ==
        (cipherIdC2s = Cipher.preferenceIntersect(
            msg.encryptionAlgorithmsClientToServer))) {
      throw FormatException('$hostport: negotiate c2s cipher');
    } else if (0 ==
        (cipherIdS2c = Cipher.preferenceIntersect(
            msg.encryptionAlgorithmsServerToClient))) {
      throw FormatException('$hostport: negotiate s2c cipher');
    } else if (0 ==
        (macIdC2s = MAC.preferenceIntersect(msg.macAlgorithmsClientToServer))) {
      throw FormatException('$hostport: negotiate c2s mac');
    } else if (0 ==
        (macIdS2c = MAC.preferenceIntersect(msg.macAlgorithmsServerToClient))) {
      throw FormatException('$hostport: negotiate s2c mac');
    } else if (0 ==
        (compressIdC2s = Compression.preferenceIntersect(
            msg.compressionAlgorithmsClientToServer, compress ? 0 : 1))) {
      throw FormatException('$hostport: negotiate c2s compression');
    } else if (0 ==
        (compressIdS2c = Compression.preferenceIntersect(
            msg.compressionAlgorithmsServerToClient, compress ? 0 : 1))) {
      throw FormatException('$hostport: negotiate s2c compression');
    }

    guessedRightS = kexMethod == KEX.id(msg.kexAlgorithms.split(',')[0]) &&
        hostkeyType == Key.id(msg.serverHostKeyAlgorithms.split(',')[0]);
    guessedRightC = kexMethod == 1 && hostkeyType == 1;
    encryptBlockSize = Cipher.blockSize(cipherIdC2s);
    decryptBlockSize = Cipher.blockSize(cipherIdS2c);
    macAlgoC2s = MAC.mac(macIdC2s);
    macPrefixC2s = MAC.prefixBytes(macIdC2s);
    macAlgoS2c = MAC.mac(macIdS2c);
    macPrefixS2c = MAC.prefixBytes(macIdS2c);

    if (print != null) {
      print('$hostport: ssh negotiated { kex=${KEX.name(kexMethod)}, hostkey=${Key.name(hostkeyType)}' +
          (cipherIdC2s == cipherIdS2c
              ? ', cipher=${Cipher.name(cipherIdC2s)}'
              : ', cipherC2s=${Cipher.name(cipherIdC2s)}, cipherS2c=${Cipher.name(cipherIdS2c)}') +
          (macIdC2s == macIdS2c
              ? ', mac=${MAC.name(macIdC2s)}'
              : ', macC2s=${MAC.name(macIdC2s)},  macS2c=${MAC.name(macIdS2c)}') +
          (compressIdC2s == compressIdS2c
              ? ', compress=${Compression.name(compressIdC2s)}'
              : ', compressC2s=${Compression.name(compressIdC2s)}, compressS2c=${Compression.name(compressIdS2c)}') +
          " }");
    }
    if (tracePrint != null) {
      tracePrint(
          '$hostport: blockSize=$encryptBlockSize,$decryptBlockSize, macLen=$macLenC,$macLenS');
    }

    if (KEX.x25519DiffieHellman(kexMethod)) {
      kexHash = SHA256Digest();
      x25519dh.GeneratePair(random);
      writeClearOrEncrypted(MSG_KEX_ECDH_INIT(x25519dh.myPubKey));
    } else if (KEX.ellipticCurveDiffieHellman(kexMethod)) {
      /* */
    } else if (KEX.diffieHellmanGroupExchange(kexMethod)) {
      /* */
    } else if (KEX.diffieHellman(kexMethod)) {
      /* */
    } else {
      throw FormatException('$hostport: unkown kex method: $kexMethod');
    }
  }

  void handleMSG_KEXDH_REPLY(int packetId, Uint8List packet) {
    if (state != SSHClientState.FIRST_KEXREPLY &&
        state != SSHClientState.KEXREPLY) {
      throw FormatException('$hostport: unexpected state $state');
    }
    if (guessedS && !guessedRightS) {
      guessedS = false;
      if (print != null) {
        print('$hostport: server guessed wrong, ignoring packet');
      }
      return;
    }

    Uint8List fingerprint;
    if (packetId == MSG_KEX_ECDH_REPLY.ID &&
        KEX.x25519DiffieHellman(kexMethod)) {
      fingerprint = handleX25519MSG_KEX_ECDH_REPLY(
              MSG_KEX_ECDH_REPLY()..deserialize(packetS)) ??
          fingerprint;
      // fall thru
    } else if (packetId == MSG_KEXDH_REPLY.ID &&
        KEX.ellipticCurveDiffieHellman(kexMethod)) {
      /**/
    } else if (packetId == MSG_KEXDH_REPLY.ID &&
        KEX.diffieHellmanGroupExchange(kexMethod)) {
      /**/
    } else {
      /**/
      throw FormatException('$hostport: unsupported $packetId, $kexMethod');
    }

    writeClearOrEncrypted(MSG_NEWKEYS());
    if (state == SSHClientState.FIRST_KEXREPLY) {
      state = SSHClientState.FIRST_NEWKEYS;
      if (hostFingerprint != null) {
        acceptedHostkey = hostFingerprint(hostkeyType, fingerprint);
      } else {
        acceptedHostkey = true;
      }
    } else {
      state = SSHClientState.NEWKEYS;
    }
  }

  Uint8List handleX25519MSG_KEX_ECDH_REPLY(MSG_KEX_ECDH_REPLY msg) {
    Uint8List fingerprint;
    if (tracePrint != null) {
      tracePrint('$hostport: MSG_KEX_ECDH_REPLY for X25519DH');
    }
    if (!acceptedHostkey) fingerprint = msg.kS;

    x25519dh.remotePubKey = msg.qS;
    K = x25519dh.computeSecret();
    if (!computeExchangeHashAndVerifyHostKey(msg.kS, msg.hSig)) {
      throw FormatException('$hostport: verify hostkey failed');
    }

    return fingerprint;
  }

  void handleMSG_NEWKEYS() {
    if (state != SSHClientState.FIRST_NEWKEYS &&
        state != SSHClientState.NEWKEYS) {
      throw FormatException('$hostport: unexpected state $state');
    }
    if (tracePrint != null) {
      tracePrint('$hostport: MSG_NEWKEYS');
    }
    int keyLenC = Cipher.keySize(cipherIdC2s),
        keyLenS = Cipher.keySize(cipherIdS2c);
    encrypt = initCipher(
        cipherIdC2s,
        deriveKey(kexHash, sessionId, hText, K, 'A'.codeUnits[0], 24),
        deriveKey(kexHash, sessionId, hText, K, 'C'.codeUnits[0], keyLenC),
        true);
    decrypt = initCipher(
        cipherIdS2c,
        deriveKey(kexHash, sessionId, hText, K, 'B'.codeUnits[0], 24),
        deriveKey(kexHash, sessionId, hText, K, 'D'.codeUnits[0], keyLenS),
        false);
    if ((macLenC = MAC.hashSize(macIdC2s)) <= 0) {
      throw FormatException('$hostport: invalid maclen $encryptBlockSize');
    } else if ((macLenS = MAC.hashSize(macIdS2c)) <= 0) {
      throw FormatException('$hostport: invalid maclen $encryptBlockSize');
    }
    integrityC2s =
        deriveKey(kexHash, sessionId, hText, K, 'E'.codeUnits[0], macLenC);
    integrityS2c =
        deriveKey(kexHash, sessionId, hText, K, 'F'.codeUnits[0], macLenS);
    state = SSHClientState.NEWKEYS;
    writeCipher(MSG_SERVICE_REQUEST('ssh-userauth'));
  }

  void handleMSG_SERVICE_ACCEPT() {
    if (tracePrint != null) tracePrint('$hostport: MSG_SERVICE_ACCEPT');
    login = user;
    if (login == null || login.isEmpty) {
      loginPrompts = 1;
      response('login: ');
    }
    if (loadIdentity != null) {
      if ((identity = loadIdentity()) != null) return;
    }
    sendAuthenticationRequest();
  }

  void handleMSG_USERAUTH_FAILURE(MSG_USERAUTH_FAILURE msg) {
    if (tracePrint != null) {
      tracePrint(
          '$hostport: MSG_USERAUTH_FAILURE: auth_left="${msg.authLeft}" loadedPw=$loadedPw useauthFail=$userauthFail');
    }
    if (!loadedPw) clearPassword();
    userauthFail++;
    if (userauthFail == 1 && !wrotePw) {
      response('Password:');
      passwordPrompts = 1;
      loadPassword();
    } else {
      throw FormatException('$hostport: authorization failed');
    }
  }

  void handleMSG_USERAUTH_SUCCESS() {
    if (tracePrint != null) {
      tracePrint('$hostport: MSG_USERAUTH_SUCCESS');
    }
    /*session_channel = &channels[next_channel_id];
    session_channel->local_id = next_channel_id++;
    session_channel->window_s = initial_window_size;
    if (compress_id_c2s == SSH::Compression::OpenSSHZLib) zreader = make_unique<ZLibReader>(4096);
    if (compress_id_s2c == SSH::Compression::OpenSSHZLib) zwriter = make_unique<ZLibWriter>(4096);
    if (success_cb) success_cb();
    if (!WriteCipher(c, SSH::MSG_CHANNEL_OPEN("session", session_channel->local_id,
                                              initial_window_size, max_packet_size)))
      return ERRORv(-1, c->Name(), ": write");*/
  }

  void handleMSG_GLOBAL_REQUEST(MSG_GLOBAL_REQUEST msg) {
    if (tracePrint != null) {
      tracePrint('$hostport: MSG_GLOBAL_REQUEST request=${msg.request}');
    }
  }

  bool computeExchangeHashAndVerifyHostKey(Uint8List kS, Uint8List hSig) {
    hText = computeExchangeHash(kexMethod, kexHash, verC, verS, kexInitC,
        kexInitS, kS, K, dh, ecdh, x25519dh);
    if (state == SSHClientState.FIRST_KEXREPLY) sessionId = hText;
    if (tracePrint != null) {
      tracePrint('$hostport: H = "${hex.encode(hText)}"');
    }
    return verifyHostKey(hText, hostkeyType, kS, hSig);
  }

  BlockCipher initCipher(int cipherId, Uint8List IV, Uint8List key, bool dir) {
    BlockCipher cipher = Cipher.cipher(cipherId);
    if (tracePrint != null) {
      tracePrint('$hostport: ' +
          (dir ? 'C->S' : 'S->C') +
          ' IV  = "${hex.encode(IV)}"');
      tracePrint('$hostport: ' +
          (dir ? 'C->S' : 'S->C') +
          ' key = "${hex.encode(key)}"');
    }
    cipher.init(
        dir,
        ParametersWithIV(
            KeyParameter(key), viewUint8List(IV, 0, cipher.blockSize)));
    return cipher;
  }

  Uint8List readCipher(Uint8List m) {
    Uint8List decM = Uint8List(m.length);
    assert(m.length % decryptBlockSize == 0);
    for (int offset = 0; offset < m.length; offset += encryptBlockSize) {
      decrypt.processBlock(m, offset, decM, offset);
    }
    return decM;
  }

  void writeCipher(SSHMessage msg) {
    sequenceNumberC2s++;
    Uint8List m = msg.toBytes(zwriter, random, encryptBlockSize),
        encM = Uint8List(m.length);
    assert(m.length % encryptBlockSize == 0);
    for (int offset = 0; offset < m.length; offset += encryptBlockSize) {
      encrypt.processBlock(m, offset, encM, offset);
    }
    Uint8List mac = computeMAC(MAC.mac(macIdC2s), macLenC, m,
        sequenceNumberC2s - 1, integrityC2s, macPrefixC2s);
    socket.sendRaw(Uint8List.fromList(encM + mac));
  }

  void writeClearOrEncrypted(SSHMessage m) {
    if (state > SSHClientState.FIRST_NEWKEYS) return writeCipher(m);
    sequenceNumberC2s++;
    socket.sendRaw(m.toBytes(null, random, encryptBlockSize));
  }

  void loadPassword() {
    if (getPassword != null && (pw = getPassword()) != null) sendPassword();
  }

  void clearPassword() {
    if (pw == null) return;
    for (int i = 0; i < pw.length; i++) {
      pw[i] ^= random.nextInt(255);
    }
    pw = null;
  }

  void sendPassword() {
    response('\r\n');
    wrotePw = true;
    if (userauthFail != 0) {
      writeCipher(MSG_USERAUTH_REQUEST(
          login, 'ssh-connection', 'password', '', pw, Uint8List(0)));
    } else {
      List<Uint8List> prompt =
          List<Uint8List>.filled(passwordPrompts, Uint8List(0));
      prompt.last = pw;
      writeCipher(MSG_USERAUTH_INFO_RESPONSE(prompt));
    }
    passwordPrompts = 0;
    clearPassword();
  }

  void sendAuthenticationRequest() {
    if (identity == null) {
      // do nothing
    }
    /*else if (identity->ed25519.privkey.size()) {
      string pubkey = SSH::Ed25519Key(identity->ed25519.pubkey).ToString();
      string challenge = SSH::DeriveChallengeText(session_id, login, "ssh-connection", "publickey", "ssh-ed25519", pubkey);
      string sig = SSH::Ed25519Signature(Ed25519Sign(challenge, identity->ed25519.privkey)).ToString();
      if (!WriteCipher(c, SSH::MSG_USERAUTH_REQUEST(login, "ssh-connection", "publickey", "ssh-ed25519", pubkey, sig)))
        return ERRORv(-1, c->Name(), ": write");
      return 0;
    } else if (identity->ec) {
    } else if (identity->rsa) {
    }*/
    writeCipher(MSG_USERAUTH_REQUEST(login, 'ssh-connection',
        'keyboard-interactive', '', Uint8List(0), Uint8List(0)));
  }
}