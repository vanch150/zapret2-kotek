using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ZapretTgWsProxy
{
    internal static class ThreadSafeRng
    {
        [ThreadStatic]
        private static RandomNumberGenerator _rng;

        public static void GetBytes(byte[] buffer)
        {
            RandomNumberGenerator r = _rng;
            if (r == null)
            {
                r = RandomNumberGenerator.Create();
                _rng = r;
            }
            r.GetBytes(buffer);
        }
    }

    internal static class TaskTimeoutHelper
    {
        public static void ObserveExceptions(Task task)
        {
            if (task == null) return;
            task.ContinueWith(delegate(Task t)
            {
                if (t.Exception != null)
                {
                    GC.KeepAlive(t.Exception);
                }
            }, TaskContinuationOptions.OnlyOnFaulted);
        }

        public static Task WaitWithTimeoutAsync(Task task, int timeoutMs, string timeoutMessage, Action onTimeout)
        {
            return WaitWithTimeoutAsync(task, timeoutMs, timeoutMessage, onTimeout, CancellationToken.None);
        }

        public static async Task WaitWithTimeoutAsync(Task task, int timeoutMs, string timeoutMessage, Action onTimeout, CancellationToken ct)
        {
            if (timeoutMs < 1) timeoutMs = 1;
            ct.ThrowIfCancellationRequested();
            using (CancellationTokenSource timeoutCts = new CancellationTokenSource())
            {
                CancellationTokenSource linkedCts = null;
                try
                {
                    if (ct.CanBeCanceled)
                    {
                        try
                        {
                            linkedCts = CancellationTokenSource.CreateLinkedTokenSource(ct, timeoutCts.Token);
                        }
                        catch (ObjectDisposedException)
                        {
                            if (onTimeout != null)
                            {
                                try { onTimeout(); } catch { }
                            }
                            throw new OperationCanceledException();
                        }
                    }
                    CancellationToken waitToken = linkedCts != null ? linkedCts.Token : timeoutCts.Token;
                    Task delayTask = Task.Delay(timeoutMs, waitToken);
                    Task completed = await Task.WhenAny(task, delayTask).ConfigureAwait(false);
                    if (completed != task)
                    {
                        ObserveExceptions(task);
                        if (onTimeout != null)
                        {
                            try { onTimeout(); } catch { }
                        }
                        ct.ThrowIfCancellationRequested();
                        throw new System.TimeoutException(timeoutMessage);
                    }
                    timeoutCts.Cancel();
                }
                finally
                {
                    if (linkedCts != null)
                    {
                        try { linkedCts.Dispose(); } catch { }
                    }
                }
            }
            await task.ConfigureAwait(false);
        }

        public static Task<T> WaitWithTimeoutAsync<T>(Task<T> task, int timeoutMs, string timeoutMessage, Action onTimeout)
        {
            return WaitWithTimeoutAsync(task, timeoutMs, timeoutMessage, onTimeout, CancellationToken.None);
        }

        public static async Task<T> WaitWithTimeoutAsync<T>(Task<T> task, int timeoutMs, string timeoutMessage, Action onTimeout, CancellationToken ct)
        {
            if (timeoutMs < 1) timeoutMs = 1;
            ct.ThrowIfCancellationRequested();
            using (CancellationTokenSource timeoutCts = new CancellationTokenSource())
            {
                CancellationTokenSource linkedCts = null;
                try
                {
                    if (ct.CanBeCanceled)
                    {
                        try
                        {
                            linkedCts = CancellationTokenSource.CreateLinkedTokenSource(ct, timeoutCts.Token);
                        }
                        catch (ObjectDisposedException)
                        {
                            if (onTimeout != null)
                            {
                                try { onTimeout(); } catch { }
                            }
                            throw new OperationCanceledException();
                        }
                    }
                    CancellationToken waitToken = linkedCts != null ? linkedCts.Token : timeoutCts.Token;
                    Task delayTask = Task.Delay(timeoutMs, waitToken);
                    Task completed = await Task.WhenAny(task, delayTask).ConfigureAwait(false);
                    if (completed != task)
                    {
                        ObserveExceptions(task);
                        if (onTimeout != null)
                        {
                            try { onTimeout(); } catch { }
                        }
                        ct.ThrowIfCancellationRequested();
                        throw new System.TimeoutException(timeoutMessage);
                    }
                    timeoutCts.Cancel();
                }
                finally
                {
                    if (linkedCts != null)
                    {
                        try { linkedCts.Dispose(); } catch { }
                    }
                }
            }
            return await task.ConfigureAwait(false);
        }
    }

    internal sealed class AesCtrCipher : IDisposable
    {
        private readonly Aes _aes;
        private readonly ICryptoTransform _encryptor;
        private readonly byte[] _counter;
        private readonly byte[] _keystream;
        private int _ksIndex;

        public AesCtrCipher(byte[] key, byte[] iv)
        {
            _aes = new AesCryptoServiceProvider();
            _aes.KeySize = 256;
            _aes.BlockSize = 128;
            _aes.Mode = CipherMode.ECB;
            _aes.Padding = PaddingMode.None;
            _encryptor = _aes.CreateEncryptor(key, new byte[16]);
            _counter = new byte[16];
            Buffer.BlockCopy(iv, 0, _counter, 0, 16);
            _keystream = new byte[16];
            _ksIndex = 16;
        }

        public void UpdateInPlace(byte[] data, int offset, int length)
        {
            int end = offset + length;
            for (int i = offset; i < end; i++)
            {
                if (_ksIndex >= 16)
                {
                    _encryptor.TransformBlock(_counter, 0, 16, _keystream, 0);
                    for (int c = 15; c >= 0; c--)
                    {
                        if (++_counter[c] != 0)
                            break;
                    }
                    _ksIndex = 0;
                }
                data[i] = (byte)(data[i] ^ _keystream[_ksIndex++]);
            }
        }

        public byte[] Update(byte[] data, int offset, int length)
        {
            byte[] output = new byte[length];
            Buffer.BlockCopy(data, offset, output, 0, length);
            UpdateInPlace(output, 0, length);
            return output;
        }

        public void Dispose()
        {
            try { _encryptor.Dispose(); } catch { }
            try { _aes.Dispose(); } catch { }
        }
    }

    internal sealed class CryptoCtx : IDisposable
    {
        public readonly AesCtrCipher CltDec;
        public readonly AesCtrCipher CltEnc;
        public readonly AesCtrCipher TgEnc;
        public readonly AesCtrCipher TgDec;

        public CryptoCtx(AesCtrCipher cltDec, AesCtrCipher cltEnc, AesCtrCipher tgEnc, AesCtrCipher tgDec)
        {
            CltDec = cltDec;
            CltEnc = cltEnc;
            TgEnc = tgEnc;
            TgDec = tgDec;
        }

        public void Dispose()
        {
            CltDec.Dispose();
            CltEnc.Dispose();
            TgEnc.Dispose();
            TgDec.Dispose();
        }
    }

    internal sealed class MsgSplitter : IDisposable
    {
        private const int ShrinkThresholdBytes = 262144;
        private readonly uint _proto;
        private MemoryStream _cipherBuf = new MemoryStream();
        private MemoryStream _plainBuf = new MemoryStream();
        private bool _disabled;

        public const uint PROTO_ABRIDGED = 0xEFEFEFEF;
        public const uint PROTO_INTERMEDIATE = 0xEEEEEEEE;
        public const uint PROTO_PADDED = 0xDDDDDDDD;

        public MsgSplitter(uint proto)
        {
            _proto = proto;
            _disabled = false;
        }

        private void MaybeShrink()
        {
            if (_cipherBuf.Capacity > ShrinkThresholdBytes && _cipherBuf.Length <= ShrinkThresholdBytes / 4)
            {
                byte[] rem = _cipherBuf.Length > 0 ? _cipherBuf.ToArray() : null;
                _cipherBuf.Dispose();
                _cipherBuf = new MemoryStream();
                if (rem != null)
                    _cipherBuf.Write(rem, 0, rem.Length);
            }
            if (_plainBuf.Capacity > ShrinkThresholdBytes && _plainBuf.Length <= ShrinkThresholdBytes / 4)
            {
                byte[] rem = _plainBuf.Length > 0 ? _plainBuf.ToArray() : null;
                _plainBuf.Dispose();
                _plainBuf = new MemoryStream();
                if (rem != null)
                    _plainBuf.Write(rem, 0, rem.Length);
            }
        }

        public List<byte[]> Split(byte[] cipherChunk, byte[] plainChunk)
        {
            List<byte[]> parts = new List<byte[]>();
            if (cipherChunk == null || cipherChunk.Length == 0)
                return parts;
            if (_disabled)
            {
                parts.Add(cipherChunk);
                return parts;
            }

            _cipherBuf.Write(cipherChunk, 0, cipherChunk.Length);
            _plainBuf.Write(plainChunk, 0, plainChunk.Length);

            byte[] cArr = _cipherBuf.GetBuffer();
            byte[] pArr = _plainBuf.GetBuffer();
            int bufLen = (int)_cipherBuf.Length;
            int offset = 0;

            while (offset < bufLen)
            {
                int avail = bufLen - offset;
                int pktLen = NextPacketLen(pArr, offset, avail);
                if (pktLen == -1)
                    break;
                if (pktLen <= 0)
                {
                    int rem = bufLen - offset;
                    byte[] tail = new byte[rem];
                    Buffer.BlockCopy(cArr, offset, tail, 0, rem);
                    parts.Add(tail);
                    offset = bufLen;
                    _disabled = true;
                    break;
                }
                byte[] slice = new byte[pktLen];
                Buffer.BlockCopy(cArr, offset, slice, 0, pktLen);
                parts.Add(slice);
                offset += pktLen;
            }

            if (offset > 0)
            {
                int remaining = bufLen - offset;
                if (remaining > 0)
                {
                    byte[] newC = new byte[remaining];
                    byte[] newP = new byte[remaining];
                    Buffer.BlockCopy(cArr, offset, newC, 0, remaining);
                    Buffer.BlockCopy(pArr, offset, newP, 0, remaining);
                    _cipherBuf.SetLength(0);
                    _plainBuf.SetLength(0);
                    if (remaining <= ShrinkThresholdBytes / 4)
                        MaybeShrink();
                    _cipherBuf.Write(newC, 0, remaining);
                    _plainBuf.Write(newP, 0, remaining);
                }
                else
                {
                    _cipherBuf.SetLength(0);
                    _plainBuf.SetLength(0);
                    MaybeShrink();
                }
            }
            else if (_cipherBuf.Capacity > ShrinkThresholdBytes && bufLen <= ShrinkThresholdBytes / 4)
            {
                MaybeShrink();
            }
            return parts;
        }

        public byte[] Flush()
        {
            if (_cipherBuf.Length == 0)
                return null;
            byte[] tail = _cipherBuf.ToArray();
            _cipherBuf.SetLength(0);
            _plainBuf.SetLength(0);
            MaybeShrink();
            return tail;
        }

        private int NextPacketLen(byte[] plain, int offset, int avail)
        {
            if (avail <= 0)
                return -1;
            if (_proto == PROTO_ABRIDGED)
            {
                byte first = plain[offset];
                int payloadLen;
                int headerLen;
                if (first == 0x7F || first == 0xFF)
                {
                    if (avail < 4)
                        return -1;
                    payloadLen = (plain[offset + 1] | (plain[offset + 2] << 8) | (plain[offset + 3] << 16)) * 4;
                    headerLen = 4;
                }
                else
                {
                    payloadLen = (first & 0x7F) * 4;
                    headerLen = 1;
                }
                if (payloadLen <= 0 || payloadLen > 16 * 1024 * 1024)
                    return 0;
                int total = headerLen + payloadLen;
                return avail < total ? -1 : total;
            }
            if (_proto == PROTO_INTERMEDIATE || _proto == PROTO_PADDED)
            {
                if (avail < 4)
                    return -1;
                uint raw = (uint)(plain[offset] | (plain[offset + 1] << 8) | (plain[offset + 2] << 16) | (plain[offset + 3] << 24));
                int payloadLen = (int)(raw & 0x7FFFFFFFU);
                if (payloadLen <= 0 || payloadLen > 16 * 1024 * 1024)
                    return 0;
                int total = 4 + payloadLen;
                return avail < total ? -1 : total;
            }
            return 0;
        }

        public void Dispose()
        {
            try { _cipherBuf.Dispose(); } catch { }
            try { _plainBuf.Dispose(); } catch { }
        }
    }

    internal sealed class CfRouteSpec
    {
        public readonly string TargetHost; // Clean Anycast IP or null for DNS host
        public readonly int Port;
        public readonly bool Secure;
        public readonly string SniOverride; // null = use Host header
        public readonly string BaseDomain;
        public readonly string Label;

        public CfRouteSpec(string targetHost, int port, bool secure, string sniOverride, string baseDomain, string label)
        {
            TargetHost = targetHost;
            Port = port;
            Secure = secure;
            SniOverride = sniOverride;
            BaseDomain = baseDomain;
            Label = label;
        }
    }

    internal sealed class RawWebSocket : IDisposable
    {
        private const int WriteTimeoutMs = 30000;
        private static volatile bool _tls13Supported = true;

        private readonly TcpClient _tcp;
        private readonly Stream _stream;
        private readonly SemaphoreSlim _writeLock = new SemaphoreSlim(1, 1);
        private MemoryStream _frag = new MemoryStream();
        private bool _inFrag;
        private volatile bool _closed;
        private int _disposed;
        internal bool FromPool;
        public readonly DateTime CreatedUtc;
        public readonly string RouteLabel;

        public bool IsClosed
        {
            get { return _closed; }
        }

        internal static void EnableTcpKeepAlive(TcpClient tcp)
        {
            if (tcp == null) return;
            try
            {
                Socket s = tcp.Client;
                if (s == null) return;
                byte[] inOptionValues = new byte[12];
                BitConverter.GetBytes((uint)1).CopyTo(inOptionValues, 0);
                BitConverter.GetBytes((uint)30000).CopyTo(inOptionValues, 4);
                BitConverter.GetBytes((uint)10000).CopyTo(inOptionValues, 8);
                s.IOControl(IOControlCode.KeepAliveValues, inOptionValues, null);
            }
            catch { }
        }

        internal static TcpClient CreateTcpClientForTarget(string targetHost, out IPAddress parsedIp)
        {
            if (IPAddress.TryParse(targetHost, out parsedIp))
            {
                return new TcpClient(parsedIp.AddressFamily);
            }
            parsedIp = null;
            TcpClient dual = null;
            try
            {
                dual = new TcpClient(AddressFamily.InterNetworkV6);
                dual.Client.DualMode = true;
                return dual;
            }
            catch
            {
                if (dual != null) { try { dual.Close(); } catch { } }
                return new TcpClient();
            }
        }

        private RawWebSocket(TcpClient tcp, Stream stream, string routeLabel)
        {
            _tcp = tcp;
            _stream = stream;
            CreatedUtc = DateTime.UtcNow;
            RouteLabel = routeLabel;
        }

        public bool IsStale(double maxAgeSec)
        {
            if (_closed || _tcp == null || !_tcp.Connected)
                return true;
            if ((DateTime.UtcNow - CreatedUtc).TotalSeconds >= maxAgeSec)
                return true;
            try
            {
                Socket s = _tcp.Client;
                if (s == null) return true;
                if (s.Poll(0, SelectMode.SelectRead) || s.Poll(0, SelectMode.SelectError))
                    return true;
            }
            catch
            {
                return true;
            }
            return false;
        }

        public static Task<RawWebSocket> ConnectAsync(
            string targetHost, int port, string hostHeader, string path,
            string sniHost, bool secure, int bufferSize, int timeoutMs, string routeLabel)
        {
            return ConnectAsync(targetHost, port, hostHeader, path, sniHost, secure, bufferSize, timeoutMs, routeLabel, CancellationToken.None);
        }

        public static async Task<RawWebSocket> ConnectAsync(
            string targetHost, int port, string hostHeader, string path,
            string sniHost, bool secure, int bufferSize, int timeoutMs, string routeLabel, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            IPAddress parsedIp;
            TcpClient tcp = CreateTcpClientForTarget(targetHost, out parsedIp);
            SslStream sslRef = null;
            try
            {
                tcp.NoDelay = true;
                tcp.ReceiveBufferSize = bufferSize;
                tcp.SendBufferSize = bufferSize;
                EnableTcpKeepAlive(tcp);

                TcpClient tcpToClose = tcp;
                Task connectTask = parsedIp != null
                    ? tcp.ConnectAsync(parsedIp, port)
                    : tcp.ConnectAsync(targetHost, port);
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    connectTask,
                    timeoutMs,
                    "TCP connect timeout to " + targetHost + ":" + port,
                    delegate { tcpToClose.Close(); },
                    ct).ConfigureAwait(false);

                Stream netStream = tcp.GetStream();
                if (secure)
                {
                    bool certValidationFailed = false;
                    SslStream ssl = new SslStream(netStream, false, delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
                    {
                        if (errors != SslPolicyErrors.None)
                        {
                            certValidationFailed = true;
                            return false;
                        }
                        return true;
                    });
                    sslRef = ssl;

                    bool tryTls13 = _tls13Supported;
                    SslProtocols protos = tryTls13 ? (SslProtocols.Tls12 | (SslProtocols)0x3000) : SslProtocols.Tls12;
                    bool fallbackTls12 = false;
                    bool needReconnect = false;
                    try
                    {
                        TcpClient tlsClose1 = tcp;
                        await TaskTimeoutHelper.WaitWithTimeoutAsync(
                            ssl.AuthenticateAsClientAsync(sniHost, null, protos, false),
                            timeoutMs,
                            "TLS handshake timeout (" + sniHost + ")",
                            delegate { tlsClose1.Close(); },
                            ct).ConfigureAwait(false);
                    }
                    catch (ArgumentException)
                    {
                        if (!tryTls13) throw;
                        _tls13Supported = false;
                        fallbackTls12 = true;
                    }
                    catch (NotSupportedException)
                    {
                        if (!tryTls13) throw;
                        _tls13Supported = false;
                        fallbackTls12 = true;
                    }
                    catch (System.ComponentModel.Win32Exception wex)
                    {
                        if (!tryTls13 || certValidationFailed || (wex is SocketException)) throw;
                        _tls13Supported = false;
                        fallbackTls12 = true;
                        needReconnect = true;
                    }
                    catch (IOException ioEx)
                    {
                        if (!tryTls13 || certValidationFailed || !(ioEx.InnerException is System.ComponentModel.Win32Exception) || (ioEx.InnerException is SocketException))
                            throw;
                        _tls13Supported = false;
                        fallbackTls12 = true;
                        needReconnect = true;
                    }
                    catch (System.Security.Authentication.AuthenticationException)
                    {
                        if (!tryTls13 || certValidationFailed) throw;
                        _tls13Supported = false;
                        fallbackTls12 = true;
                        needReconnect = true;
                    }
                    if (fallbackTls12)
                    {
                        ct.ThrowIfCancellationRequested();
                        if (needReconnect)
                        {
                            try { ssl.Dispose(); } catch { }
                            try { tcp.Close(); } catch { }
                            tcp = CreateTcpClientForTarget(targetHost, out parsedIp);
                            tcp.NoDelay = true;
                            tcp.ReceiveBufferSize = bufferSize;
                            tcp.SendBufferSize = bufferSize;
                            EnableTcpKeepAlive(tcp);
                            TcpClient tcpReconnect = tcp;
                            Task reconnectTask = parsedIp != null
                                ? tcp.ConnectAsync(parsedIp, port)
                                : tcp.ConnectAsync(targetHost, port);
                            await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                reconnectTask,
                                timeoutMs,
                                "TCP reconnect timeout to " + targetHost + ":" + port,
                                delegate { tcpReconnect.Close(); },
                                ct).ConfigureAwait(false);
                            netStream = tcp.GetStream();
                            ssl = new SslStream(netStream, false, delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
                            {
                                return errors == SslPolicyErrors.None;
                            });
                            sslRef = ssl;
                        }
                        TcpClient tlsClose2 = tcp;
                        await TaskTimeoutHelper.WaitWithTimeoutAsync(
                            ssl.AuthenticateAsClientAsync(sniHost, null, SslProtocols.Tls12, false),
                            timeoutMs,
                            "TLS 1.2 handshake timeout (" + sniHost + ")",
                            delegate { tlsClose2.Close(); },
                            ct).ConfigureAwait(false);
                    }
                    sslRef = ssl;
                    netStream = ssl;
                }

                byte[] keyBytes = new byte[16];
                ThreadSafeRng.GetBytes(keyBytes);
                string wsKey = Convert.ToBase64String(keyBytes);

                string safePath = (path ?? "/apiws").Replace("\r", "").Replace("\n", "");
                string safeHost = (hostHeader ?? "").Replace("\r", "").Replace("\n", "");
                string req =
                    "GET " + safePath + " HTTP/1.1\r\n" +
                    "Host: " + safeHost + "\r\n" +
                    "Upgrade: websocket\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: " + wsKey + "\r\n" +
                    "Sec-WebSocket-Version: 13\r\n" +
                    "Sec-WebSocket-Protocol: binary\r\n" +
                    "User-Agent: Mozilla/5.0\r\n\r\n";

                Stopwatch hsSw = Stopwatch.StartNew();
                TcpClient hsTcp = tcp;
                byte[] reqBytes = Encoding.ASCII.GetBytes(req);
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    netStream.WriteAsync(reqBytes, 0, reqBytes.Length),
                    timeoutMs,
                    "WS upgrade write timeout",
                    delegate { hsTcp.Close(); },
                    ct).ConfigureAwait(false);
                int flushRemain = timeoutMs - (int)hsSw.ElapsedMilliseconds;
                if (flushRemain <= 0)
                    throw new System.TimeoutException("WS upgrade handshake deadline exceeded");
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    netStream.FlushAsync(),
                    flushRemain,
                    "WS upgrade flush timeout",
                    delegate { hsTcp.Close(); },
                    ct).ConfigureAwait(false);

                int statusRemain = timeoutMs - (int)hsSw.ElapsedMilliseconds;
                if (statusRemain <= 0)
                    throw new System.TimeoutException("WS upgrade handshake deadline exceeded");
                string statusLine = await ReadLineAsciiAsync(netStream, statusRemain, ct).ConfigureAwait(false);
                if (string.IsNullOrEmpty(statusLine))
                    throw new IOException("Empty WS upgrade response from " + targetHost + ":" + port);

                string acceptHeader = null;
                int hdrCount = 0;
                while (true)
                {
                    if (++hdrCount > 64)
                        throw new IOException("WS upgrade: too many response headers");
                    int hdrRemain = timeoutMs - (int)hsSw.ElapsedMilliseconds;
                    if (hdrRemain <= 0)
                        throw new System.TimeoutException("WS upgrade handshake deadline exceeded");
                    string hdrLine = await ReadLineAsciiAsync(netStream, hdrRemain, ct).ConfigureAwait(false);
                    if (hdrLine == null)
                        throw new EndOfStreamException("WS upgrade handshake truncated (EOF)");
                    if (hdrLine.Length == 0)
                        break;
                    if (hdrLine.StartsWith("Sec-WebSocket-Accept:", StringComparison.OrdinalIgnoreCase))
                        acceptHeader = hdrLine.Substring(21).Trim();
                }

                if (!statusLine.StartsWith("HTTP/1.1 101", StringComparison.OrdinalIgnoreCase))
                    throw new IOException("WS upgrade rejected (" + statusLine + ")");

                string expectedAccept;
                using (SHA1 sha1 = SHA1.Create())
                {
                    byte[] hash = sha1.ComputeHash(Encoding.ASCII.GetBytes(wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
                    expectedAccept = Convert.ToBase64String(hash);
                }
                if (!string.Equals(acceptHeader, expectedAccept, StringComparison.Ordinal))
                    throw new IOException("Invalid Sec-WebSocket-Accept from " + targetHost + ":" + port);

                return new RawWebSocket(tcp, netStream, routeLabel);
            }
            catch
            {
                if (sslRef != null) { try { sslRef.Dispose(); } catch { } }
                try { tcp.Close(); } catch { }
                throw;
            }
        }

        private static async Task<string> ReadLineAsciiAsync(Stream stream, int timeoutMs, CancellationToken ct)
        {
            if (timeoutMs < 1) timeoutMs = 1;
            ct.ThrowIfCancellationRequested();
            using (MemoryStream ms = new MemoryStream(128))
            using (CancellationTokenSource timeoutCts = new CancellationTokenSource(timeoutMs))
            {
                CancellationTokenSource linkedCts = null;
                try
                {
                    if (ct.CanBeCanceled)
                    {
                        try
                        {
                            linkedCts = CancellationTokenSource.CreateLinkedTokenSource(ct, timeoutCts.Token);
                        }
                        catch (ObjectDisposedException)
                        {
                            throw new OperationCanceledException();
                        }
                    }
                    CancellationToken waitToken = linkedCts != null ? linkedCts.Token : timeoutCts.Token;
                    byte[] one = new byte[1];
                    Task timeoutTask = Task.Delay(Timeout.Infinite, waitToken);
                    int totalRead = 0;
                    bool sawLf = false;
                    while (totalRead < 8192)
                    {
                        Task<int> rt = stream.ReadAsync(one, 0, 1);
                        if (!rt.IsCompleted)
                        {
                            Task done = await Task.WhenAny(rt, timeoutTask).ConfigureAwait(false);
                            if (done != rt)
                            {
                                TaskTimeoutHelper.ObserveExceptions(rt);
                                ct.ThrowIfCancellationRequested();
                                throw new System.TimeoutException("WS header read timeout");
                            }
                        }
                        int n = await rt.ConfigureAwait(false);
                        if (n <= 0)
                            return null;
                        totalRead++;
                        if (one[0] == (byte)'\n')
                        {
                            sawLf = true;
                            break;
                        }
                        if (one[0] != (byte)'\r')
                            ms.WriteByte(one[0]);
                    }
                    if (!sawLf)
                        throw new IOException("WS response header line too long");
                    return Encoding.ASCII.GetString(ms.ToArray());
                }
                finally
                {
                    if (linkedCts != null)
                    {
                        try { linkedCts.Dispose(); } catch { }
                    }
                }
            }
        }

        public Task SendBinaryAsync(byte[] data)
        {
            return SendBinaryAsync(data, CancellationToken.None);
        }

        public async Task SendBinaryAsync(byte[] data, CancellationToken ct)
        {
            if (_closed) throw new ObjectDisposedException("RawWebSocket");
            ct.ThrowIfCancellationRequested();
            byte[] frame = BuildFrame(0x02, data, 0, data.Length);
            await _writeLock.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (_closed) throw new ObjectDisposedException("RawWebSocket");
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    _stream.WriteAsync(frame, 0, frame.Length),
                    WriteTimeoutMs,
                    "WS write timeout",
                    delegate { CloseTransport(); },
                    ct).ConfigureAwait(false);
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    _stream.FlushAsync(),
                    WriteTimeoutMs,
                    "WS flush timeout",
                    delegate { CloseTransport(); },
                    ct).ConfigureAwait(false);
            }
            finally
            {
                try { _writeLock.Release(); } catch { }
            }
        }

        public Task SendBatchAsync(List<byte[]> parts)
        {
            return SendBatchAsync(parts, CancellationToken.None);
        }

        public async Task SendBatchAsync(List<byte[]> parts, CancellationToken ct)
        {
            if (_closed) throw new ObjectDisposedException("RawWebSocket");
            ct.ThrowIfCancellationRequested();
            byte[] all;
            using (MemoryStream batch = new MemoryStream())
            {
                for (int i = 0; i < parts.Count; i++)
                {
                    byte[] f = BuildFrame(0x02, parts[i], 0, parts[i].Length);
                    batch.Write(f, 0, f.Length);
                }
                all = batch.ToArray();
            }
            await _writeLock.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (_closed) throw new ObjectDisposedException("RawWebSocket");
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    _stream.WriteAsync(all, 0, all.Length),
                    WriteTimeoutMs,
                    "WS batch write timeout",
                    delegate { CloseTransport(); },
                    ct).ConfigureAwait(false);
                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                    _stream.FlushAsync(),
                    WriteTimeoutMs,
                    "WS batch flush timeout",
                    delegate { CloseTransport(); },
                    ct).ConfigureAwait(false);
            }
            finally
            {
                try { _writeLock.Release(); } catch { }
            }
        }

        public Task<byte[]> ReceiveAsync()
        {
            return ReceiveAsync(CancellationToken.None);
        }

        public async Task<byte[]> ReceiveAsync(CancellationToken ct)
        {
            while (!_closed && !ct.IsCancellationRequested)
            {
                byte[] hdr = await ReadExactlyAsync(_stream, 2).ConfigureAwait(false);
                if (hdr == null)
                    return null;
                bool fin = (hdr[0] & 0x80) != 0;
                int rsv = hdr[0] & 0x70;
                int opcode = hdr[0] & 0x0F;
                bool masked = (hdr[1] & 0x80) != 0;
                long len = hdr[1] & 0x7F;

                if (rsv != 0)
                    throw new IOException("Invalid WS frame: non-zero RSV bits (0x" + rsv.ToString("X2") + ")");
                if ((opcode >= 0x03 && opcode <= 0x07) || opcode >= 0x0B)
                    throw new IOException("Invalid WS reserved opcode: 0x" + opcode.ToString("X2"));
                if (opcode == 0x01)
                    throw new IOException("Unexpected WS text frame (0x01) on binary MTProto stream");

                if (len == 126)
                {
                    byte[] ext2 = await ReadExactlyAsync(_stream, 2).ConfigureAwait(false);
                    if (ext2 == null) return null;
                    len = (ext2[0] << 8) | ext2[1];
                }
                else if (len == 127)
                {
                    byte[] ext8 = await ReadExactlyAsync(_stream, 8).ConfigureAwait(false);
                    if (ext8 == null) return null;
                    len = 0;
                    for (int i = 0; i < 8; i++)
                        len = (len << 8) | ext8[i];
                }

                if (opcode >= 0x08 && (!fin || len > 125))
                    throw new IOException("Invalid WS control frame (fin=" + fin + ", len=" + len + ")");

                if (len < 0 || len > 16 * 1024 * 1024)
                    throw new IOException("WS frame too large: " + len);

                byte[] maskKey = null;
                if (masked)
                {
                    maskKey = await ReadExactlyAsync(_stream, 4).ConfigureAwait(false);
                    if (maskKey == null) return null;
                }

                byte[] payload = len > 0
                    ? await ReadExactlyAsync(_stream, (int)len).ConfigureAwait(false)
                    : new byte[0];
                if (payload == null)
                    return null;

                if (masked && maskKey != null)
                {
                    for (int i = 0; i < payload.Length; i++)
                        payload[i] ^= maskKey[i & 3];
                }

                if (opcode == 0x08)
                {
                    _closed = true;
                    try
                    {
                        byte[] closePayload;
                        if (payload.Length == 0)
                            closePayload = new byte[0];
                        else if (payload.Length == 1)
                            closePayload = new byte[] { 0x03, 0xEA }; // 1002 Protocol Error (never echo 1-byte close)
                        else
                            closePayload = new byte[] { payload[0], payload[1] };
                        byte[] closeReply = BuildFrame(0x08, closePayload, 0, closePayload.Length);
                        await _writeLock.WaitAsync(ct).ConfigureAwait(false);
                        try
                        {
                            await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                _stream.WriteAsync(closeReply, 0, closeReply.Length),
                                WriteTimeoutMs,
                                "WS control write timeout",
                                delegate { CloseTransport(); },
                                ct).ConfigureAwait(false);
                            await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                _stream.FlushAsync(),
                                WriteTimeoutMs,
                                "WS control flush timeout",
                                delegate { CloseTransport(); },
                                ct).ConfigureAwait(false);
                        }
                        finally { try { _writeLock.Release(); } catch { } }
                    }
                    catch { }
                    return null;
                }
                if (opcode == 0x09)
                {
                    try
                    {
                        byte[] pong = BuildFrame(0x0A, payload, 0, payload.Length);
                        await _writeLock.WaitAsync(ct).ConfigureAwait(false);
                        try
                        {
                            await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                _stream.WriteAsync(pong, 0, pong.Length),
                                WriteTimeoutMs,
                                "WS control write timeout",
                                delegate { CloseTransport(); },
                                ct).ConfigureAwait(false);
                            await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                _stream.FlushAsync(),
                                WriteTimeoutMs,
                                "WS control flush timeout",
                                delegate { CloseTransport(); },
                                ct).ConfigureAwait(false);
                        }
                        finally { try { _writeLock.Release(); } catch { } }
                    }
                    catch { }
                    continue;
                }
                if (opcode == 0x0A)
                    continue;

                if (opcode == 0x00 || opcode == 0x02)
                {
                    if (opcode == 0x00 && !_inFrag)
                        throw new IOException("Unexpected WS continuation frame");
                    if (opcode == 0x02 && _inFrag)
                        throw new IOException("Unexpected WS data frame during fragmentation");

                    if (fin && !_inFrag)
                        return payload;
                    _inFrag = true;
                    if (_frag.Length + payload.Length > 16 * 1024 * 1024)
                        throw new IOException("WS fragmented message too large");
                    _frag.Write(payload, 0, payload.Length);
                    if (!fin)
                        continue;
                    _inFrag = false;
                    byte[] msg = _frag.ToArray();
                    if (_frag.Capacity > 262144)
                    {
                        try { _frag.Dispose(); } catch { }
                        _frag = new MemoryStream();
                    }
                    else
                    {
                        _frag.SetLength(0);
                    }
                    return msg;
                }
            }
            return null;
        }

        private static byte[] BuildFrame(byte opcode, byte[] data, int offset, int length)
        {
            byte[] maskKey = new byte[4];
            ThreadSafeRng.GetBytes(maskKey);

            int hdrLen = length < 126 ? 6 : (length < 65536 ? 8 : 14);
            byte[] frame = new byte[hdrLen + length];
            frame[0] = (byte)(0x80 | opcode);

            int maskOffset;
            if (length < 126)
            {
                frame[1] = (byte)(0x80 | length);
                maskOffset = 2;
            }
            else if (length < 65536)
            {
                frame[1] = 0x80 | 126;
                frame[2] = (byte)((length >> 8) & 0xFF);
                frame[3] = (byte)(length & 0xFF);
                maskOffset = 4;
            }
            else
            {
                frame[1] = 0x80 | 127;
                long l = length;
                for (int i = 9; i >= 2; i--)
                {
                    frame[i] = (byte)(l & 0xFF);
                    l >>= 8;
                }
                maskOffset = 10;
            }

            Buffer.BlockCopy(maskKey, 0, frame, maskOffset, 4);
            for (int i = 0; i < length; i++)
                frame[hdrLen + i] = (byte)(data[offset + i] ^ maskKey[i & 3]);

            return frame;
        }

        internal static async Task<byte[]> ReadExactlyAsync(Stream stream, int count)
        {
            byte[] buf = new byte[count];
            int readTotal = 0;
            while (readTotal < count)
            {
                int n = await stream.ReadAsync(buf, readTotal, count - readTotal).ConfigureAwait(false);
                if (n <= 0)
                    return null;
                readTotal += n;
            }
            return buf;
        }

        public void CloseTransport()
        {
            _closed = true;
            try { _stream.Close(); } catch { }
            try { _tcp.Close(); } catch { }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;
            CloseTransport();
            try { _frag.Dispose(); } catch { }
            try { _writeLock.Dispose(); } catch { }
        }
    }

    public sealed class TgWsProxyEngine : IDisposable
    {
        private const int MaxConcurrentClients = 384;
        private const int DirectCircuitBreakerThreshold = 3;

        public string Host = "127.0.0.1";
        public int Port = 1443;
        public string SecretHex = "";
        public byte[] SecretBytes;
        public string Mode = "smart"; // smart | direct | cfonly
        public int PoolSize = 4;
        public int BufferSize = 256 * 1024;
        public bool FallbackCfProxy = true;
        public bool DisableSecure = false;
        public string LogFile = "";
        public bool Verbose = false;
        private string _invalidPortRaw = null;

        public readonly ConcurrentDictionary<int, string> DcRedirects = new ConcurrentDictionary<int, string>();
        private readonly HashSet<int> _userDcRedirects = new HashSet<int>();
        public readonly List<string> CfUserDomains = new List<string>();
        public readonly List<string> CfWorkerDomains = new List<string>();

        private static readonly Dictionary<int, string> DcDefaultIps = new Dictionary<int, string>
        {
            { 1, "149.154.175.50" },
            { 2, "149.154.167.51" },
            { 3, "149.154.175.100" },
            { 4, "149.154.167.91" },
            { 5, "149.154.171.5" },
            { 203, "91.105.192.100" }
        };

        // Official Telegram WebSocket gateways across multiple subnets
        private static readonly string[] DirectWsCandidateIps = new string[]
        {
            "149.154.167.220",
            "149.154.167.99",
            "91.108.56.130",
            "149.154.175.50"
        };

        // Clean Cloudflare Anycast Edge IPs not blackholed at TCP SYN on Russian ISPs
        private static readonly string[] CleanCfAnycastIps = new string[]
        {
            "104.16.132.229",
            "104.17.24.14",
            "104.18.32.47",
            "172.64.155.209"
        };

        private static readonly string[] DefaultCfDomains = new string[]
        {
            "pclead.co.uk", "offshor.co.uk", "cakeisalie.co.uk", "noskomnadzor.co.uk",
            "lovetrue.co.uk", "sorokdva.co.uk", "pyatdesyatdva.co.uk", "kartoshka.co.uk",
            "sorokodin.co.uk", "pyatdesyatodin.co.uk", "notelega.co.uk", "ebally.co.uk",
            "nebally.co.uk", "havegreatday.co.uk", "pomogite.co.uk", "fixtelega.co.uk",
            "sadnews.co.uk", "onedaychamp.co.uk", "stopblocking.co.uk", "nothingthere.co.uk"
        };

        private readonly List<string> _cfDomains = new List<string>(DefaultCfDomains);
        private readonly ConcurrentDictionary<string, ConcurrentQueue<RawWebSocket>> _wsPool = new ConcurrentDictionary<string, ConcurrentQueue<RawWebSocket>>();
        private readonly ConcurrentDictionary<int, ConcurrentQueue<RawWebSocket>> _cfPool = new ConcurrentDictionary<int, ConcurrentQueue<RawWebSocket>>();
        private readonly ConcurrentDictionary<string, int> _refilling = new ConcurrentDictionary<string, int>();
        private readonly SemaphoreSlim _connSlots = new SemaphoreSlim(MaxConcurrentClients, MaxConcurrentClients);
        private readonly object _logLock = new object();

        // -1 = unknown, 0 = unreachable (circuit breaker open), 1 = reachable
        private int _directWsState = -1;
        private int _directFailStreak = 0;
        private volatile string _workingDirectIp = "149.154.167.220";
        private long _lastDirectProbeUtcMs = 0;
        private readonly SemaphoreSlim _directProbeLock = new SemaphoreSlim(1, 1);

        private CfRouteSpec _bestCfRoute = null;
        private readonly SemaphoreSlim _cfProbeLock = new SemaphoreSlim(1, 1);

        private readonly ConcurrentDictionary<TcpClient, byte> _activeClients = new ConcurrentDictionary<TcpClient, byte>();
        private readonly ConcurrentDictionary<RawWebSocket, byte> _activeWs = new ConcurrentDictionary<RawWebSocket, byte>();
        private readonly ConcurrentDictionary<TcpClient, byte> _activeFallbackTcp = new ConcurrentDictionary<TcpClient, byte>();
        private readonly ConcurrentDictionary<Task, byte> _inflightTasks = new ConcurrentDictionary<Task, byte>();
        private TcpListener _listener;
        private CancellationTokenSource _stopCts;
        private Task _acceptTask;
        private Task _warmupTask;
        private Task _sweepTask;
        private volatile bool _running;
        private int _stopCalled;
        private int _disposed;

        public static bool IsAllowedDc(int dc)
        {
            return (dc >= 1 && dc <= 5) || dc == 203 || (dc >= 10001 && dc <= 10005);
        }

        public bool AddUserDcRedirect(int dc, string ipText)
        {
            if (!IsAllowedDc(dc) || string.IsNullOrWhiteSpace(ipText))
                return false;
            IPAddress parsed;
            if (!IPAddress.TryParse(ipText.Trim(), out parsed))
                return false;
            int normDc = dc >= 10000 ? dc - 10000 : dc;
            DcRedirects[normDc] = parsed.ToString();
            _userDcRedirects.Add(normDc);
            return true;
        }

        internal void SetPortFromText(string v)
        {
            int p;
            if (int.TryParse((v ?? "").Trim(), out p))
            {
                Port = p;
                _invalidPortRaw = null;
            }
            else
            {
                Port = -1;
                _invalidPortRaw = v;
            }
        }

        internal static string NormalizeCfDomain(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
                return "";
            string s = raw.Trim();
            if (s.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                s = s.Substring(8);
            else if (s.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
                s = s.Substring(7);
            int slash = s.IndexOf('/');
            if (slash >= 0)
                s = s.Substring(0, slash);
            return s.Trim();
        }

        internal static void AddUniqueDomain(List<string> list, string raw)
        {
            string dom = NormalizeCfDomain(raw);
            if (string.IsNullOrEmpty(dom))
                return;
            for (int i = 0; i < list.Count; i++)
            {
                if (string.Equals(list[i], dom, StringComparison.OrdinalIgnoreCase))
                    return;
            }
            list.Add(dom);
        }

        private static void NormalizeAndDeduplicateDomains(List<string> list)
        {
            List<string> clean = new List<string>(list.Count);
            for (int i = 0; i < list.Count; i++)
                AddUniqueDomain(clean, list[i]);
            list.Clear();
            list.AddRange(clean);
        }

        private static bool IsReparsePoint(string path)
        {
            try
            {
                if (File.Exists(path) || Directory.Exists(path))
                {
                    FileAttributes attr = File.GetAttributes(path);
                    return (attr & FileAttributes.ReparsePoint) != 0;
                }
            }
            catch
            {
                return true;
            }
            return false;
        }

        private static string ValidateLogFilePath(string rawPath)
        {
            if (string.IsNullOrWhiteSpace(rawPath))
                return "";
            string binDir = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\') + "\\";
            string logsDir = Path.Combine(binDir, "logs") + "\\";
            string candLog = Path.GetFullPath(Path.IsPathRooted(rawPath) ? rawPath : Path.Combine(logsDir, rawPath));
            if (!candLog.StartsWith(logsDir, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("LogFile must reside inside bin\\logs\\ directory: " + rawPath);

            string binRootNoSlash = binDir.TrimEnd('\\');
            string logDir = Path.GetDirectoryName(candLog);
            string curDir = logDir;
            while (!string.IsNullOrEmpty(curDir))
            {
                if (IsReparsePoint(curDir))
                    throw new ArgumentException("LogFile directory chain contains a reparse point: " + curDir);
                if (curDir.TrimEnd('\\').Equals(binRootNoSlash, StringComparison.OrdinalIgnoreCase))
                    break;
                string nextDir = Path.GetDirectoryName(curDir);
                if (string.IsNullOrEmpty(nextDir) || nextDir.Equals(curDir, StringComparison.OrdinalIgnoreCase))
                    break;
                if (!nextDir.StartsWith(binRootNoSlash, StringComparison.OrdinalIgnoreCase))
                    break;
                curDir = nextDir;
            }
            if (!string.IsNullOrEmpty(logDir) && !Directory.Exists(logDir))
            {
                try { Directory.CreateDirectory(logDir); } catch { }
            }
            if (!string.IsNullOrEmpty(logDir) && IsReparsePoint(logDir))
                throw new ArgumentException("LogFile directory is a reparse point: " + logDir);
            if (IsReparsePoint(candLog))
                throw new ArgumentException("LogFile is a reparse point: " + candLog);
            return candLog;
        }

        public void LoadConfigFile(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
                return;
            foreach (string rawLine in File.ReadAllLines(path, Encoding.UTF8))
            {
                string line = rawLine.Trim();
                if (string.IsNullOrEmpty(line) || line.StartsWith("#") || line.StartsWith(";"))
                    continue;
                int eq = line.IndexOf('=');
                if (eq <= 0)
                    continue;
                string k = line.Substring(0, eq).Trim().ToLowerInvariant();
                string v = line.Substring(eq + 1).Trim();
                if (k == "host" && !string.IsNullOrEmpty(v)) Host = v;
                else if (k == "port" && !string.IsNullOrEmpty(v)) SetPortFromText(v);
                else if (k == "secret" && !string.IsNullOrEmpty(v)) SecretHex = v;
                else if (k == "mode" && !string.IsNullOrEmpty(v)) Mode = v.ToLowerInvariant();
                else if (k == "pool_size") { int ps; if (int.TryParse(v, out ps) && ps >= 0) PoolSize = ps; }
                else if (k == "cfproxy_domain" && !string.IsNullOrEmpty(v))
                {
                    foreach (string d in v.Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                        AddUniqueDomain(CfUserDomains, d);
                }
                else if (k == "cfproxy_worker_domain" && !string.IsNullOrEmpty(v))
                {
                    foreach (string d in v.Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                        AddUniqueDomain(CfWorkerDomains, d);
                }
                else if (k == "log_file" && !string.IsNullOrEmpty(v)) LogFile = v;
                else if (k == "verbose") Verbose = (v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase));
            }
        }

        public void FinalizeConfig()
        {
            LogFile = ValidateLogFilePath(LogFile);

            string h = (Host ?? "").Trim();
            if (h.Equals("localhost", StringComparison.OrdinalIgnoreCase))
            {
                Host = "127.0.0.1";
            }
            else if (h == "127.0.0.1" || h == "::1")
            {
                Host = h;
            }
            else
            {
                string hostErr = "Invalid Host '" + h + "': only loopback (127.0.0.1, ::1, localhost) is allowed.";
                Log("ERROR", hostErr);
                throw new ArgumentException(hostErr);
            }

            if (Port <= 0 || Port >= 65536)
            {
                string portErr = _invalidPortRaw != null
                    ? ("Invalid Port '" + _invalidPortRaw + "' (expected 1-65535).")
                    : ("Invalid Port: " + Port);
                Log("ERROR", portErr);
                throw new ArgumentException(portErr);
            }

            string m = (Mode ?? "smart").Trim().ToLowerInvariant();
            if (m != "smart" && m != "direct" && m != "cfonly")
            {
                string modeErr = "Invalid Mode '" + m + "': expected smart, direct, or cfonly.";
                Log("ERROR", modeErr);
                throw new ArgumentException(modeErr);
            }
            Mode = m;
            if (Mode == "direct")
                FallbackCfProxy = false;

            string rawSecret = (SecretHex ?? "").Trim();
            if (string.IsNullOrEmpty(rawSecret))
            {
                byte[] sb = new byte[16];
                ThreadSafeRng.GetBytes(sb);
                SecretHex = BytesToHex(sb);
            }
            else if (rawSecret.Length == 34 && rawSecret.StartsWith("dd", StringComparison.OrdinalIgnoreCase) && IsValidHex32(rawSecret.Substring(2)))
            {
                SecretHex = rawSecret.Substring(2).ToLowerInvariant();
                Log("INFO", "Secret had 34-char 'dd' prefix; stripped 'dd' to 32-hex secret.");
            }
            else if (IsValidHex32(rawSecret))
            {
                SecretHex = rawSecret.ToLowerInvariant();
            }
            else
            {
                string secErr = "Invalid Secret '" + rawSecret + "': expected 32 hex chars (or 34-char 'dd' + 32 hex chars).";
                Log("ERROR", secErr);
                throw new ArgumentException(secErr);
            }
            SecretBytes = HexToBytes(SecretHex);

            if (PoolSize < 0)
                PoolSize = 4;

            NormalizeAndDeduplicateDomains(CfUserDomains);
            NormalizeAndDeduplicateDomains(CfWorkerDomains);
            if (CfUserDomains.Count > 0)
            {
                _cfDomains.Clear();
                _cfDomains.AddRange(CfUserDomains);
            }
        }

        public void Log(string level, string msg)
        {
            if (level == "DEBUG" && !Verbose)
                return;
            string line = string.Format("{0:yyyy-MM-dd HH:mm:ss}  {1,-5}  {2}", DateTime.Now, level, msg);
            lock (_logLock)
            {
                if (Environment.UserInteractive)
                {
                    try { Console.WriteLine(line); } catch { }
                }
                if (!string.IsNullOrEmpty(LogFile))
                {
                    try
                    {
                        if (IsReparsePoint(LogFile))
                            return;
                        try
                        {
                            FileInfo fi = new FileInfo(LogFile);
                            if (fi.Exists && fi.Length > 5 * 1024 * 1024)
                            {
                                string bak = LogFile + ".1";
                                if (!IsReparsePoint(bak))
                                {
                                    File.Copy(LogFile, bak, true);
                                    using (FileStream truncFs = new FileStream(LogFile, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                                    {
                                        truncFs.SetLength(0);
                                    }
                                }
                            }
                        }
                        catch { }
                        byte[] bytes = Encoding.UTF8.GetBytes(line + Environment.NewLine);
                        using (FileStream fs = new FileStream(LogFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                        {
                            fs.Write(bytes, 0, bytes.Length);
                        }
                    }
                    catch { }
                }
            }
        }

        private void TrackTask(Task t)
        {
            if (t == null) return;
            _inflightTasks.TryAdd(t, 0);
            t.ContinueWith(delegate(Task done)
            {
                byte dummy;
                _inflightTasks.TryRemove(done, out dummy);
                if (done.IsFaulted && done.Exception != null)
                    GC.KeepAlive(done.Exception);
            }, TaskContinuationOptions.ExecuteSynchronously);
        }

        private static CancellationTokenRegistration RegisterCancelSafe(CancellationToken ct, Action callback)
        {
            if (!ct.CanBeCanceled)
                return new CancellationTokenRegistration();
            try
            {
                return ct.Register(callback);
            }
            catch (ObjectDisposedException)
            {
                try { callback(); } catch { }
                return new CancellationTokenRegistration();
            }
        }

        public void Start()
        {
            FinalizeConfig();
            Interlocked.Exchange(ref _stopCalled, 0);
            _running = true;
            CancellationTokenSource cts = new CancellationTokenSource();
            _stopCts = cts;
            try
            {
                IPAddress bindIp;
                if (!IPAddress.TryParse(Host, out bindIp))
                    bindIp = IPAddress.Loopback;

                _listener = new TcpListener(bindIp, Port);
                _listener.Server.ExclusiveAddressUse = true;
                _listener.Start(128);
            }
            catch
            {
                _running = false;
                Interlocked.CompareExchange(ref _stopCts, null, cts);
                try { if (_listener != null) _listener.Stop(); } catch { }
                _listener = null;
                try { cts.Cancel(); } catch { }
                try { cts.Dispose(); } catch { }
                throw;
            }

            Log("INFO", "============================================================");
            Log("INFO", "  Zapret2 Native Telegram MTProto WS Bridge Proxy");
            Log("INFO", string.Format("  Listening on   {0}:{1} (Mode: {2})", Host, Port, Mode));
            string maskedSecret = (SecretHex != null && SecretHex.Length >= 8) ? (SecretHex.Substring(0, 4) + "..." + SecretHex.Substring(SecretHex.Length - 4)) : "***";
            Log("INFO", "  Secret:        " + maskedSecret + " (redacted)");
            Log("INFO", string.Format("  Connect Link:  tg://proxy?server={0}&port={1}&secret=dd{2}", Host, Port, maskedSecret));
            Log("INFO", "============================================================");

            CancellationToken stopToken = cts.Token;
            _warmupTask = Task.Run(delegate { return WarmupPoolsAsync(stopToken); });
            TaskTimeoutHelper.ObserveExceptions(_warmupTask);
            _sweepTask = Task.Run(delegate { return SweepPoolsLoopAsync(stopToken); });
            TaskTimeoutHelper.ObserveExceptions(_sweepTask);
            _acceptTask = Task.Run(delegate { return AcceptLoopAsync(stopToken); });
            TaskTimeoutHelper.ObserveExceptions(_acceptTask);
        }

        public void Stop()
        {
            if (Interlocked.Exchange(ref _stopCalled, 1) != 0)
                return;

            bool wasStarted = _running || _listener != null || _stopCts != null;
            _running = false;
            CancellationTokenSource cts = _stopCts;
            try { if (cts != null) cts.Cancel(); } catch { }
            try { if (_listener != null) _listener.Stop(); } catch { }
            _listener = null;

            foreach (KeyValuePair<TcpClient, byte> kv in _activeClients)
            {
                try { kv.Key.Close(); } catch { }
            }
            _activeClients.Clear();

            foreach (KeyValuePair<RawWebSocket, byte> kv in _activeWs)
            {
                try { kv.Key.CloseTransport(); } catch { }
            }
            _activeWs.Clear();

            foreach (KeyValuePair<TcpClient, byte> kv in _activeFallbackTcp)
            {
                try { kv.Key.Close(); } catch { }
            }
            _activeFallbackTcp.Clear();

            List<Task> bgTasks = new List<Task>();
            Task acceptTask = _acceptTask;
            Task warmupTask = _warmupTask;
            Task sweepTask = _sweepTask;
            _acceptTask = null;
            _warmupTask = null;
            _sweepTask = null;
            if (acceptTask != null) bgTasks.Add(acceptTask);
            if (warmupTask != null) bgTasks.Add(warmupTask);
            if (sweepTask != null) bgTasks.Add(sweepTask);
            foreach (KeyValuePair<Task, byte> kv in _inflightTasks)
            {
                bgTasks.Add(kv.Key);
            }

            bool allDone = true;
            if (bgTasks.Count > 0)
            {
                try { allDone = Task.WaitAll(bgTasks.ToArray(), 2500); } catch { allDone = false; }
            }

            DrainAllPools();
            if (allDone)
            {
                Interlocked.CompareExchange(ref _stopCts, null, cts);
                try { if (cts != null) cts.Dispose(); } catch { }
            }
            if (wasStarted)
                Log("INFO", "Proxy stopped.");
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;
            Stop();
            CancellationTokenSource cts = Interlocked.Exchange(ref _stopCts, null);
            try { if (cts != null) cts.Dispose(); } catch { }
            try { _connSlots.Dispose(); } catch { }
            try { _directProbeLock.Dispose(); } catch { }
            try { _cfProbeLock.Dispose(); } catch { }
        }

        private void DrainAllPools()
        {
            foreach (KeyValuePair<string, ConcurrentQueue<RawWebSocket>> kv in _wsPool)
            {
                RawWebSocket ws;
                while (kv.Value.TryDequeue(out ws))
                    ws.Dispose();
            }
            foreach (KeyValuePair<int, ConcurrentQueue<RawWebSocket>> kv in _cfPool)
            {
                RawWebSocket ws;
                while (kv.Value.TryDequeue(out ws))
                    ws.Dispose();
            }
        }

        private void EnqueueDirectSafe(ConcurrentQueue<RawWebSocket> q, RawWebSocket ws)
        {
            if (!_running || PoolSize <= 0)
            {
                ws.Dispose();
                return;
            }
            q.Enqueue(ws);
            if (!_running || PoolSize <= 0)
            {
                RawWebSocket stale;
                while (q.TryDequeue(out stale))
                    stale.Dispose();
            }
        }

        private void EnqueueCfSafe(ConcurrentQueue<RawWebSocket> q, RawWebSocket ws)
        {
            if (!_running || PoolSize <= 0)
            {
                ws.Dispose();
                return;
            }
            q.Enqueue(ws);
            if (!_running || PoolSize <= 0)
            {
                RawWebSocket stale;
                while (q.TryDequeue(out stale))
                    stale.Dispose();
            }
        }

        private async Task SweepPoolsLoopAsync(CancellationToken ct)
        {
            while (_running && !ct.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(30000, ct).ConfigureAwait(false);
                }
                catch
                {
                    break;
                }
                if (!_running || ct.IsCancellationRequested) break;

                foreach (KeyValuePair<string, ConcurrentQueue<RawWebSocket>> kv in _wsPool)
                {
                    int n = kv.Value.Count;
                    for (int i = 0; i < n; i++)
                    {
                        RawWebSocket ws;
                        if (!kv.Value.TryDequeue(out ws)) break;
                        if (ws.IsStale(95.0) || !_running)
                            ws.Dispose();
                        else
                            EnqueueDirectSafe(kv.Value, ws);
                    }
                }
                foreach (KeyValuePair<int, ConcurrentQueue<RawWebSocket>> kv in _cfPool)
                {
                    int n = kv.Value.Count;
                    for (int i = 0; i < n; i++)
                    {
                        RawWebSocket ws;
                        if (!kv.Value.TryDequeue(out ws)) break;
                        if (ws.IsStale(85.0) || !_running)
                            ws.Dispose();
                        else
                            EnqueueCfSafe(kv.Value, ws);
                    }
                }
            }
        }

        private async Task WarmupPoolsAsync(CancellationToken ct)
        {
            try
            {
                if (!_running || ct.IsCancellationRequested)
                    return;
                if (Mode != "cfonly")
                {
                    bool directOk = await EnsureDirectWsProbedAsync(ct).ConfigureAwait(false);
                    if (!_running || ct.IsCancellationRequested)
                        return;
                    if (directOk && PoolSize > 0)
                    {
                        ScheduleDirectRefill(2, false, ct);
                        ScheduleDirectRefill(4, false, ct);
                        if (Mode == "direct")
                            ScheduleDirectRefill(2, true, ct);
                    }
                }

                if (!_running || ct.IsCancellationRequested || !FallbackCfProxy)
                    return;

                // Warm up CF route/pool for Smart Media / CF-only / Direct-blocked fallback
                RawWebSocket probeCf = await ConnectCfFastAsync(2, ct).ConfigureAwait(false);
                if (probeCf != null)
                {
                    if (!_running || ct.IsCancellationRequested || PoolSize <= 0)
                    {
                        probeCf.Dispose();
                        return;
                    }
                    ConcurrentQueue<RawWebSocket> q2 = _cfPool.GetOrAdd(2, delegate { return new ConcurrentQueue<RawWebSocket>(); });
                    EnqueueCfSafe(q2, probeCf);
                    ScheduleCfRefill(2, ct);
                    ScheduleCfRefill(4, ct);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Log("DEBUG", "Warmup error: " + ex.Message);
            }
        }

        private async Task<bool> EnsureDirectWsProbedAsync(CancellationToken ct)
        {
            if (Mode == "cfonly" || ct.IsCancellationRequested)
                return false;

            long backoffMs = (Mode == "direct" || !FallbackCfProxy) ? 20000L : 180000L;
            int state = Volatile.Read(ref _directWsState);
            long nowMs = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond;
            if (state == 1)
                return true;
            if (state == 0 && (nowMs - Interlocked.Read(ref _lastDirectProbeUtcMs)) < backoffMs)
                return false;

            try
            {
                await _directProbeLock.WaitAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return false; }
            catch (ObjectDisposedException) { return false; }
            try
            {
                if (ct.IsCancellationRequested)
                    return false;
                state = Volatile.Read(ref _directWsState);
                nowMs = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond;
                if (state == 1)
                    return true;
                if (state == 0 && (nowMs - Interlocked.Read(ref _lastDirectProbeUtcMs)) < backoffMs)
                    return false;

                Interlocked.Exchange(ref _lastDirectProbeUtcMs, nowMs);

                List<Task<RawWebSocket>> tasks = new List<Task<RawWebSocket>>();
                List<string> taskIps = new List<string>();
                for (int i = 0; i < DirectWsCandidateIps.Length; i++)
                {
                    string ip = DirectWsCandidateIps[i];
                    taskIps.Add(ip);
                    tasks.Add(RawWebSocket.ConnectAsync(
                        ip, 443, "kws4.web.telegram.org", "/apiws", "kws4.web.telegram.org", true, BufferSize, 2200, "direct:" + ip, ct));
                }

                List<Task<RawWebSocket>> pending = new List<Task<RawWebSocket>>(tasks);
                while (pending.Count > 0)
                {
                    if (ct.IsCancellationRequested)
                    {
                        CleanupRemainingTasks(pending);
                        return false;
                    }
                    Task<RawWebSocket> finished = await Task.WhenAny(pending).ConfigureAwait(false);
                    pending.Remove(finished);
                    if (finished.Status == TaskStatus.RanToCompletion && finished.Result != null)
                    {
                        RawWebSocket winner = finished.Result;
                        if (ct.IsCancellationRequested)
                        {
                            winner.Dispose();
                            CleanupRemainingTasks(pending);
                            return false;
                        }
                        int idx = tasks.IndexOf(finished);
                        string winIp = idx >= 0 ? taskIps[idx] : "149.154.167.220";
                        _workingDirectIp = winIp;
                        if (!_userDcRedirects.Contains(2)) DcRedirects[2] = winIp;
                        if (!_userDcRedirects.Contains(4)) DcRedirects[4] = winIp;
                        Interlocked.Exchange(ref _directFailStreak, 0);
                        Interlocked.Exchange(ref _directWsState, 1);
                        Log("INFO", "Direct Telegram WS reachable via " + winIp);

                        if (PoolSize > 0 && _running)
                        {
                            ConcurrentQueue<RawWebSocket> q4 = _wsPool.GetOrAdd("4", delegate { return new ConcurrentQueue<RawWebSocket>(); });
                            EnqueueDirectSafe(q4, winner);
                        }
                        else
                        {
                            winner.Dispose();
                        }

                        CleanupRemainingTasks(pending);
                        return true;
                    }
                    else if (finished.IsFaulted && finished.Exception != null)
                    {
                        GC.KeepAlive(finished.Exception);
                    }
                }

                if (ct.IsCancellationRequested)
                    return false;

                long failNowMs = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond;
                Interlocked.Exchange(ref _lastDirectProbeUtcMs, failNowMs);
                Interlocked.Exchange(ref _directWsState, 0);
                Log("INFO", "Direct Telegram WS IPs blocked by ISP (timeout) -> Instant Cloudflare Clean-IP routing enabled.");
                return false;
            }
            finally
            {
                try { _directProbeLock.Release(); } catch (ObjectDisposedException) { }
            }
        }

        private static void CleanupRemainingTasks(List<Task<RawWebSocket>> pending)
        {
            for (int i = 0; i < pending.Count; i++)
            {
                Task<RawWebSocket> t = pending[i];
                t.ContinueWith(delegate(Task<RawWebSocket> done)
                {
                    if (done.IsFaulted)
                    {
                        if (done.Exception != null) GC.KeepAlive(done.Exception);
                        return;
                    }
                    if (done.Status == TaskStatus.RanToCompletion && done.Result != null)
                    {
                        try { done.Result.Dispose(); } catch { }
                    }
                });
            }
        }

        private void ScheduleDirectRefill(int dc, bool isMedia, CancellationToken ct)
        {
            if (!_running || ct.IsCancellationRequested || PoolSize <= 0 || Volatile.Read(ref _directWsState) != 1)
                return;
            string key = dc.ToString() + (isMedia ? "m" : "");
            if (!_refilling.TryAdd("d:" + key, 1))
                return;

            Task refillTask = Task.Run(async delegate
            {
                try
                {
                    ConcurrentQueue<RawWebSocket> q = _wsPool.GetOrAdd(key, delegate { return new ConcurrentQueue<RawWebSocket>(); });
                    int needed = Math.Max(0, Math.Min(PoolSize, 3) - q.Count);
                    for (int i = 0; i < needed && _running && !ct.IsCancellationRequested && Volatile.Read(ref _directWsState) == 1; i++)
                    {
                        string targetIp;
                        if (!DcRedirects.TryGetValue(dc, out targetIp) || string.IsNullOrEmpty(targetIp))
                            targetIp = _workingDirectIp;
                        RawWebSocket ws = await ConnectDirectWsAsync(dc, isMedia, targetIp, ct).ConfigureAwait(false);
                        if (ws != null) EnqueueDirectSafe(q, ws);
                        else break;
                    }
                }
                finally
                {
                    int dummy;
                    _refilling.TryRemove("d:" + key, out dummy);
                }
            });
            TrackTask(refillTask);
        }

        private void ScheduleCfRefill(int dc, CancellationToken ct)
        {
            if (!_running || ct.IsCancellationRequested || PoolSize <= 0 || !FallbackCfProxy)
                return;
            string rKey = "cf:" + dc.ToString();
            if (!_refilling.TryAdd(rKey, 1))
                return;

            Task refillTask = Task.Run(async delegate
            {
                try
                {
                    ConcurrentQueue<RawWebSocket> q = _cfPool.GetOrAdd(dc, delegate { return new ConcurrentQueue<RawWebSocket>(); });
                    int target = (dc == 2 || dc == 4) ? Math.Min(PoolSize, 3) : 1;
                    int needed = target - q.Count;
                    for (int i = 0; i < needed && _running && !ct.IsCancellationRequested; i++)
                    {
                        RawWebSocket ws = await ConnectCfFastAsync(dc, ct).ConfigureAwait(false);
                        if (ws != null) EnqueueCfSafe(q, ws);
                        else break;
                    }
                }
                finally
                {
                    int dummy;
                    _refilling.TryRemove(rKey, out dummy);
                }
            });
            TrackTask(refillTask);
        }

        private async Task<RawWebSocket> GetPooledDirectWsAsync(int dc, bool isMedia, bool skipPool, CancellationToken ct)
        {
            if (Mode == "cfonly" || !_running || ct.IsCancellationRequested)
                return null;

            int normDc = dc == 203 ? 2 : dc;
            if (normDc < 1 || normDc > 5)
                return null;

            bool reachable = await EnsureDirectWsProbedAsync(ct).ConfigureAwait(false);
            if (!reachable || !_running || ct.IsCancellationRequested)
                return null;

            string key = dc.ToString() + (isMedia ? "m" : "");
            if (!skipPool)
            {
                ConcurrentQueue<RawWebSocket> q;
                if (_wsPool.TryGetValue(key, out q))
                {
                    RawWebSocket ws;
                    while (q.TryDequeue(out ws))
                    {
                        if (ws.IsStale(95.0))
                        {
                            ws.Dispose();
                            continue;
                        }
                        ws.FromPool = true;
                        ScheduleDirectRefill(dc, isMedia, ct);
                        return ws;
                    }
                }
            }

            ScheduleDirectRefill(dc, isMedia, ct);
            string targetIp;
            if (!DcRedirects.TryGetValue(dc, out targetIp) || string.IsNullOrEmpty(targetIp))
                targetIp = _workingDirectIp;
            return await ConnectDirectWsAsync(dc, isMedia, targetIp, ct).ConfigureAwait(false);
        }

        private async Task<RawWebSocket> GetPooledCfWsAsync(int dc, bool skipPool, CancellationToken ct)
        {
            if (!FallbackCfProxy || !_running || ct.IsCancellationRequested)
                return null;

            if (!skipPool)
            {
                ConcurrentQueue<RawWebSocket> q;
                if (_cfPool.TryGetValue(dc, out q))
                {
                    RawWebSocket ws;
                    while (q.TryDequeue(out ws))
                    {
                        if (ws.IsStale(85.0))
                        {
                            ws.Dispose();
                            continue;
                        }
                        ws.FromPool = true;
                        ScheduleCfRefill(dc, ct);
                        return ws;
                    }
                }
            }

            ScheduleCfRefill(dc, ct);
            return await ConnectCfFastAsync(dc, ct).ConfigureAwait(false);
        }

        private async Task<RawWebSocket> ConnectDirectWsAsync(int dc, bool isMedia, string targetIp, CancellationToken ct)
        {
            if (ct.IsCancellationRequested)
                return null;
            int normDc = dc == 203 ? 2 : dc;
            string domain = isMedia
                ? string.Format("kws{0}-1.web.telegram.org", normDc)
                : string.Format("kws{0}.web.telegram.org", normDc);

            try
            {
                RawWebSocket ws = await RawWebSocket.ConnectAsync(
                    targetIp, 443, domain, "/apiws", domain, true, BufferSize, 2500, "direct:" + domain + "@" + targetIp, ct).ConfigureAwait(false);
                Interlocked.Exchange(ref _directFailStreak, 0);
                return ws;
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex)
            {
                int streak = Interlocked.Increment(ref _directFailStreak);
                if (streak >= DirectCircuitBreakerThreshold)
                {
                    long failNowMs = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond;
                    Interlocked.Exchange(ref _lastDirectProbeUtcMs, failNowMs);
                    Interlocked.Exchange(ref _directWsState, 0);
                    Log("INFO", string.Format("Direct WS circuit breaker opened after {0} failures ({1})", streak, ex.Message));
                }
                else
                {
                    Log("DEBUG", string.Format("Direct WS {0} via {1} failed ({2}/{3}): {4}", domain, targetIp, streak, DirectCircuitBreakerThreshold, ex.Message));
                }
                return null;
            }
        }

        private Task<RawWebSocket> ConnectViaSpecAsync(int normDc, CfRouteSpec spec, int timeoutMs, CancellationToken ct)
        {
            string wsHost = string.Format("kws{0}.{1}", normDc, spec.BaseDomain);
            string connectHost = string.IsNullOrEmpty(spec.TargetHost) ? wsHost : spec.TargetHost;
            string sni = string.IsNullOrEmpty(spec.SniOverride) ? wsHost : spec.SniOverride;
            string label = string.Format("{0}({1}:{2}->kws{3}.{4})", spec.Label, connectHost, spec.Port, normDc, spec.BaseDomain);
            return RawWebSocket.ConnectAsync(connectHost, spec.Port, wsHost, "/apiws", sni, spec.Secure, BufferSize, timeoutMs, label, ct);
        }

        private async Task<RawWebSocket> ConnectCfFastAsync(int dc, CancellationToken ct)
        {
            if (ct.IsCancellationRequested || !FallbackCfProxy)
                return null;

            int normDc = dc == 203 ? 2 : dc;
            string dstIp;
            DcDefaultIps.TryGetValue(dc, out dstIp);

            // 1. Custom CF Worker domains if configured
            if (CfWorkerDomains.Count > 0 && !string.IsNullOrEmpty(dstIp))
            {
                string path = string.Format("/apiws?dst={0}&dc={1}", Uri.EscapeDataString(dstIp), dc);
                for (int i = 0; i < CfWorkerDomains.Count && !ct.IsCancellationRequested; i++)
                {
                    string wDom = CfWorkerDomains[i];
                    try
                    {
                        int cfPort = DisableSecure ? 80 : 443;
                        RawWebSocket ws = await RawWebSocket.ConnectAsync(
                            CleanCfAnycastIps[0], cfPort, wDom, path, wDom, !DisableSecure, BufferSize, 3200, "cf-worker:" + wDom, ct).ConfigureAwait(false);
                        return ws;
                    }
                    catch (OperationCanceledException) { return null; }
                    catch { }
                    if (ct.IsCancellationRequested) return null;
                    try
                    {
                        int port = DisableSecure ? 80 : 443;
                        RawWebSocket ws = await RawWebSocket.ConnectAsync(
                            wDom, port, wDom, path, wDom, !DisableSecure, BufferSize, 3200, "cf-worker:" + wDom, ct).ConfigureAwait(false);
                        return ws;
                    }
                    catch (OperationCanceledException) { return null; }
                    catch { }
                }
            }

            if (_cfDomains.Count == 0 || ct.IsCancellationRequested)
                return null;

            // 2. Fast-path using cached winning route spec
            CfRouteSpec cached = Volatile.Read(ref _bestCfRoute);
            if (cached != null)
            {
                try
                {
                    RawWebSocket fastWs = await ConnectViaSpecAsync(normDc, cached, 3200, ct).ConfigureAwait(false);
                    if (fastWs != null)
                        return fastWs;
                }
                catch (OperationCanceledException)
                {
                    return null;
                }
                catch (Exception ex)
                {
                    Log("DEBUG", "Cached CF route failed (" + cached.Label + "): " + ex.Message);
                    Interlocked.CompareExchange(ref _bestCfRoute, null, cached);
                }
            }

            if (ct.IsCancellationRequested)
                return null;

            // 3. Single-flight check/race: release _cfProbeLock BEFORE opening connection with cached winner
            CfRouteSpec winnerCached = null;
            try
            {
                await _cfProbeLock.WaitAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return null; }
            catch (ObjectDisposedException) { return null; }
            try
            {
                if (ct.IsCancellationRequested)
                    return null;
                winnerCached = Volatile.Read(ref _bestCfRoute);
                if (winnerCached == null)
                    return await RaceCfRoutesAsync(normDc, 4200, ct).ConfigureAwait(false);
            }
            finally
            {
                try { _cfProbeLock.Release(); } catch (ObjectDisposedException) { }
            }

            try
            {
                RawWebSocket wsFromWinner = await ConnectViaSpecAsync(normDc, winnerCached, 3200, ct).ConfigureAwait(false);
                if (wsFromWinner != null)
                    return wsFromWinner;
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex)
            {
                Log("DEBUG", "Cached CF route failed (" + winnerCached.Label + "): " + ex.Message);
                Interlocked.CompareExchange(ref _bestCfRoute, null, winnerCached);
            }

            if (ct.IsCancellationRequested)
                return null;

            CfRouteSpec recheck = null;
            try
            {
                await _cfProbeLock.WaitAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return null; }
            catch (ObjectDisposedException) { return null; }
            try
            {
                if (ct.IsCancellationRequested)
                    return null;
                recheck = Volatile.Read(ref _bestCfRoute);
                if (recheck == null)
                    return await RaceCfRoutesAsync(normDc, 4200, ct).ConfigureAwait(false);
            }
            finally
            {
                try { _cfProbeLock.Release(); } catch (ObjectDisposedException) { }
            }

            try
            {
                return await ConnectViaSpecAsync(normDc, recheck, 3200, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex)
            {
                Log("DEBUG", "CF route retry failed (" + recheck.Label + "): " + ex.Message);
                Interlocked.CompareExchange(ref _bestCfRoute, null, recheck);
                return null;
            }
        }

        private async Task<RawWebSocket> RaceCfCandidateGroupAsync(int normDc, List<CfRouteSpec> specs, int timeoutMs, CancellationToken ct)
        {
            if (specs == null || specs.Count == 0 || ct.IsCancellationRequested)
                return null;

            List<Task<RawWebSocket>> tasks = new List<Task<RawWebSocket>>(specs.Count);
            List<Task<RawWebSocket>> pending = new List<Task<RawWebSocket>>(specs.Count);
            for (int i = 0; i < specs.Count; i++)
            {
                Task<RawWebSocket> t = ConnectViaSpecAsync(normDc, specs[i], timeoutMs, ct);
                tasks.Add(t);
                pending.Add(t);
            }

            while (pending.Count > 0)
            {
                if (ct.IsCancellationRequested)
                {
                    CleanupRemainingTasks(pending);
                    return null;
                }
                Task<RawWebSocket> done = await Task.WhenAny(pending).ConfigureAwait(false);
                pending.Remove(done);
                if (done.Status == TaskStatus.RanToCompletion && done.Result != null)
                {
                    RawWebSocket winner = done.Result;
                    if (ct.IsCancellationRequested)
                    {
                        winner.Dispose();
                        CleanupRemainingTasks(pending);
                        return null;
                    }
                    int winIdx = tasks.IndexOf(done);
                    if (winIdx >= 0)
                    {
                        Volatile.Write(ref _bestCfRoute, specs[winIdx]);
                        Log("INFO", "Selected optimal Cloudflare route: " + winner.RouteLabel);
                    }
                    CleanupRemainingTasks(pending);
                    return winner;
                }
                else if (done.IsFaulted && done.Exception != null)
                {
                    GC.KeepAlive(done.Exception);
                }
            }
            return null;
        }

        private async Task<RawWebSocket> RaceCfRoutesAsync(int normDc, int timeoutMs, CancellationToken ct)
        {
            if (_cfDomains.Count == 0 || ct.IsCancellationRequested)
                return null;

            Random rnd = new Random(Environment.TickCount ^ Thread.CurrentThread.ManagedThreadId);
            int baseIdx = rnd.Next(_cfDomains.Count);
            string dom1 = _cfDomains[baseIdx];
            string dom2 = _cfDomains[(baseIdx + 7) % _cfDomains.Count];

            string ip1 = CleanCfAnycastIps[0]; // 104.16.132.229
            string ip3 = CleanCfAnycastIps[2]; // 104.18.32.47
            string ip4 = CleanCfAnycastIps[3]; // 172.64.155.209

            // Stage 1: race TLS WSS :443 candidates first to prevent plaintext ws://:80 downgrade
            if (!DisableSecure)
            {
                List<CfRouteSpec> wssSpecs = new List<CfRouteSpec>();
                wssSpecs.Add(new CfRouteSpec(ip1, 443, true, null, dom1, "cf-clean-wss"));
                wssSpecs.Add(new CfRouteSpec(ip4, 443, true, null, dom2, "cf-clean-wss"));
                wssSpecs.Add(new CfRouteSpec(null, 443, true, null, dom1, "cf-dns-wss"));
                RawWebSocket wssWinner = await RaceCfCandidateGroupAsync(normDc, wssSpecs, timeoutMs, ct).ConfigureAwait(false);
                if (wssWinner != null || ct.IsCancellationRequested)
                    return wssWinner;
                Log("INFO", "All Cloudflare WSS :443 routes failed; trying HTTP WS :80 fallback.");
            }

            // Stage 2: only try plaintext HTTP WS :80 if DisableSecure or all WSS :443 attempts failed
            List<CfRouteSpec> ws80Specs = new List<CfRouteSpec>();
            ws80Specs.Add(new CfRouteSpec(ip1, 80, false, null, dom1, "cf-clean-ws80"));
            ws80Specs.Add(new CfRouteSpec(ip3, 80, false, null, dom2, "cf-clean-ws80"));
            ws80Specs.Add(new CfRouteSpec(null, 80, false, null, dom2, "cf-dns-ws80"));
            return await RaceCfCandidateGroupAsync(normDc, ws80Specs, timeoutMs, ct).ConfigureAwait(false);
        }

        private async Task AcceptLoopAsync(CancellationToken ct)
        {
            while (_running && !ct.IsCancellationRequested)
            {
                bool acquired = false;
                bool delayAfterError = false;
                try
                {
                    await _connSlots.WaitAsync(ct).ConfigureAwait(false);
                    acquired = true;
                    TcpClient client = await _listener.AcceptTcpClientAsync().ConfigureAwait(false);
                    acquired = false; // ownership transferred to HandleClientAsync
                    TcpClient captured = client;
                    _activeClients.TryAdd(captured, 0);
                    Task clientTask = Task.Run(delegate { return HandleClientAsync(captured, ct); });
                    TrackTask(clientTask);
                }
                catch (OperationCanceledException)
                {
                    if (acquired) { try { _connSlots.Release(); } catch { } }
                    break;
                }
                catch (ObjectDisposedException)
                {
                    if (acquired) { try { _connSlots.Release(); } catch { } }
                    break;
                }
                catch (Exception ex)
                {
                    if (acquired) { try { _connSlots.Release(); } catch { } }
                    if (_running)
                        Log("WARN", "Accept error: " + ex.Message);
                    delayAfterError = true;
                }
                if (delayAfterError)
                {
                    try { await Task.Delay(200, ct).ConfigureAwait(false); } catch { break; }
                }
            }
        }

        private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
        {
            string label = "?";
            _activeClients.TryAdd(client, 0);
            try
            {
                if (!_running || ct.IsCancellationRequested)
                    return;
                client.NoDelay = true;
                client.ReceiveBufferSize = BufferSize;
                client.SendBufferSize = BufferSize;
                RawWebSocket.EnableTcpKeepAlive(client);
                if (client.Client.RemoteEndPoint != null)
                    label = client.Client.RemoteEndPoint.ToString();

                NetworkStream cltStream = client.GetStream();
                byte[] handshake;
                try
                {
                    handshake = await TaskTimeoutHelper.WaitWithTimeoutAsync(
                        RawWebSocket.ReadExactlyAsync(cltStream, 64),
                        10000,
                        "Client MTProto handshake timeout",
                        delegate { client.Close(); },
                        ct).ConfigureAwait(false);
                }
                catch (System.TimeoutException)
                {
                    return;
                }
                catch (OperationCanceledException)
                {
                    return;
                }

                if (handshake == null || handshake.Length != 64 || !_running || ct.IsCancellationRequested)
                    return;

                int dc;
                bool isMedia;
                short dcIdx;
                uint protoInt;
                byte[] protoTag;
                byte[] cltPrekeyIv;

                if (!TryParseHandshake(handshake, SecretBytes, out dc, out isMedia, out dcIdx, out protoInt, out protoTag, out cltPrekeyIv))
                {
                    Log("WARN", string.Format("[{0}] Bad MTProto handshake (check secret in Telegram Desktop)", label));
                    return;
                }

                if (dc >= 10000)
                    dc -= 10000;

                byte[] relayInit = GenerateRelayInit(protoTag, dcIdx);
                using (CryptoCtx ctx = BuildCryptoCtx(cltPrekeyIv, SecretBytes, relayInit))
                using (MsgSplitter splitter = new MsgSplitter(protoInt))
                {
                    // 1 retry on stale/closed pooled socket if SendBinaryAsync(relayInit) fails or closed after dequeue
                    for (int attempt = 0; attempt < 2; attempt++)
                    {
                        if (!_running || ct.IsCancellationRequested)
                            return;

                        bool skipPool = (attempt > 0);
                        RawWebSocket ws = await GetPooledDirectWsAsync(dc, isMedia, skipPool, ct).ConfigureAwait(false);
                        if (ws == null)
                        {
                            if (!_running || ct.IsCancellationRequested)
                                return;
                            ws = await GetPooledCfWsAsync(dc, skipPool, ct).ConfigureAwait(false);
                        }

                        if (ws == null)
                            break;
                        if (!_running || ct.IsCancellationRequested)
                        {
                            ws.Dispose();
                            return;
                        }

                        bool initSent = false;
                        using (ws)
                        {
                            if (ws.IsClosed || (ws.FromPool && ws.IsStale(95.0)))
                            {
                                Log("DEBUG", string.Format("[{0}] Stale/closed WS after dequeue (attempt {1})", label, attempt + 1));
                                continue;
                            }
                            try
                            {
                                await ws.SendBinaryAsync(relayInit, ct).ConfigureAwait(false);
                                initSent = true;
                            }
                            catch (OperationCanceledException)
                            {
                                return;
                            }
                            catch (Exception ex)
                            {
                                Log("DEBUG", string.Format("[{0}] Stale WS on relayInit (attempt {1}): {2}", label, attempt + 1, ex.Message));
                            }
                            if (initSent)
                            {
                                if (!_running || ct.IsCancellationRequested)
                                    return;
                                Log("INFO", string.Format("[{0}] DC{1}{2} -> {3}", label, dc, isMedia ? " media" : "", ws.RouteLabel));
                                await BridgeWsAsync(cltStream, ws, ctx, splitter, ct).ConfigureAwait(false);
                                return;
                            }
                        }
                    }

                    if (!_running || ct.IsCancellationRequested)
                        return;

                    if (!string.Equals(Mode, "cfonly", StringComparison.OrdinalIgnoreCase))
                    {
                        string tcpIp;
                        if (DcDefaultIps.TryGetValue(dc, out tcpIp))
                        {
                            Log("INFO", string.Format("[{0}] DC{1}{2} -> direct TCP fallback ({3}:443)", label, dc, isMedia ? " media" : "", tcpIp));
                            await BridgeTcpFallbackAsync(cltStream, tcpIp, 443, relayInit, ctx, ct).ConfigureAwait(false);
                        }
                    }
                    else
                    {
                        Log("WARN", string.Format("[{0}] DC{1}{2} -> Cloudflare WS failed (cfonly mode: direct TCP fallback disabled)", label, dc, isMedia ? " media" : ""));
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Log("DEBUG", string.Format("[{0}] Session ended: {1}", label, ex.Message));
            }
            finally
            {
                byte removed;
                _activeClients.TryRemove(client, out removed);
                try { client.Close(); } catch { }
                try { _connSlots.Release(); } catch { }
            }
        }

        private static bool TryParseHandshake(
            byte[] handshake, byte[] secret,
            out int dc, out bool isMedia, out short dcIdx,
            out uint protoInt, out byte[] protoTag, out byte[] prekeyAndIv)
        {
            dc = 0;
            isMedia = false;
            dcIdx = 0;
            protoInt = 0;
            protoTag = new byte[4];
            prekeyAndIv = new byte[48];
            Buffer.BlockCopy(handshake, 8, prekeyAndIv, 0, 48);

            byte[] prekey = new byte[32];
            byte[] iv = new byte[16];
            Buffer.BlockCopy(prekeyAndIv, 0, prekey, 0, 32);
            Buffer.BlockCopy(prekeyAndIv, 32, iv, 0, 16);

            byte[] hashInput = new byte[32 + secret.Length];
            Buffer.BlockCopy(prekey, 0, hashInput, 0, 32);
            Buffer.BlockCopy(secret, 0, hashInput, 32, secret.Length);

            byte[] decKey;
            using (SHA256 sha = SHA256.Create())
            {
                decKey = sha.ComputeHash(hashInput);
            }

            byte[] decrypted;
            using (AesCtrCipher dec = new AesCtrCipher(decKey, iv))
            {
                decrypted = dec.Update(handshake, 0, 64);
            }

            Buffer.BlockCopy(decrypted, 56, protoTag, 0, 4);
            uint tag = (uint)(protoTag[0] | (protoTag[1] << 8) | (protoTag[2] << 16) | (protoTag[3] << 24));
            if (tag != MsgSplitter.PROTO_ABRIDGED && tag != MsgSplitter.PROTO_INTERMEDIATE && tag != MsgSplitter.PROTO_PADDED)
                return false;

            protoInt = tag;
            dcIdx = (short)(decrypted[60] | (decrypted[61] << 8));
            dc = Math.Abs((int)dcIdx);
            isMedia = dcIdx < 0;
            if (!IsAllowedDc(dc))
                return false;
            return true;
        }

        private static byte[] GenerateRelayInit(byte[] protoTag, short dcIdx)
        {
            byte[] rnd = new byte[64];
            while (true)
            {
                ThreadSafeRng.GetBytes(rnd);
                if (rnd[0] == 0xEF) continue;
                uint first4 = (uint)(rnd[0] | (rnd[1] << 8) | (rnd[2] << 16) | (rnd[3] << 24));
                if (first4 == 0x44414548U || first4 == 0x54534F50U || first4 == 0x20544547U ||
                    first4 == 0xEEEEEEEEU || first4 == 0xDDDDDDDDU || first4 == 0x02010316U ||
                    first4 == 0x4954504FU)
                    continue;
                if (rnd[4] == 0 && rnd[5] == 0 && rnd[6] == 0 && rnd[7] == 0)
                    continue;
                break;
            }

            byte[] encKey = new byte[32];
            byte[] encIv = new byte[16];
            Buffer.BlockCopy(rnd, 8, encKey, 0, 32);
            Buffer.BlockCopy(rnd, 40, encIv, 0, 16);

            byte[] plainForEnc = new byte[64];
            Buffer.BlockCopy(rnd, 0, plainForEnc, 0, 64);
            Buffer.BlockCopy(protoTag, 0, plainForEnc, 56, 4);
            plainForEnc[60] = (byte)(dcIdx & 0xFF);
            plainForEnc[61] = (byte)((dcIdx >> 8) & 0xFF);

            byte[] encrypted;
            using (AesCtrCipher enc = new AesCtrCipher(encKey, encIv))
            {
                encrypted = enc.Update(plainForEnc, 0, 64);
            }

            byte[] result = new byte[64];
            Buffer.BlockCopy(rnd, 0, result, 0, 56);
            Buffer.BlockCopy(encrypted, 56, result, 56, 8);
            return result;
        }

        private static CryptoCtx BuildCryptoCtx(byte[] cltPrekeyIv, byte[] secret, byte[] relayInit)
        {
            byte[] cltDecPrekey = new byte[32];
            byte[] cltDecIv = new byte[16];
            Buffer.BlockCopy(cltPrekeyIv, 0, cltDecPrekey, 0, 32);
            Buffer.BlockCopy(cltPrekeyIv, 32, cltDecIv, 0, 16);

            byte[] revClt = new byte[48];
            for (int i = 0; i < 48; i++)
                revClt[i] = cltPrekeyIv[47 - i];

            byte[] cltEncPrekey = new byte[32];
            byte[] cltEncIv = new byte[16];
            Buffer.BlockCopy(revClt, 0, cltEncPrekey, 0, 32);
            Buffer.BlockCopy(revClt, 32, cltEncIv, 0, 16);

            byte[] cltDecKey;
            byte[] cltEncKey;
            using (SHA256 sha = SHA256.Create())
            {
                byte[] buf1 = new byte[32 + secret.Length];
                Buffer.BlockCopy(cltDecPrekey, 0, buf1, 0, 32);
                Buffer.BlockCopy(secret, 0, buf1, 32, secret.Length);
                cltDecKey = sha.ComputeHash(buf1);

                byte[] buf2 = new byte[32 + secret.Length];
                Buffer.BlockCopy(cltEncPrekey, 0, buf2, 0, 32);
                Buffer.BlockCopy(secret, 0, buf2, 32, secret.Length);
                cltEncKey = sha.ComputeHash(buf2);
            }

            byte[] relayEncKey = new byte[32];
            byte[] relayEncIv = new byte[16];
            Buffer.BlockCopy(relayInit, 8, relayEncKey, 0, 32);
            Buffer.BlockCopy(relayInit, 40, relayEncIv, 0, 16);

            byte[] revRelay = new byte[48];
            for (int i = 0; i < 48; i++)
                revRelay[i] = relayInit[55 - i];

            byte[] relayDecKey = new byte[32];
            byte[] relayDecIv = new byte[16];
            Buffer.BlockCopy(revRelay, 0, relayDecKey, 0, 32);
            Buffer.BlockCopy(revRelay, 32, relayDecIv, 0, 16);

            AesCtrCipher cltDec = null;
            AesCtrCipher cltEnc = null;
            AesCtrCipher tgEnc = null;
            AesCtrCipher tgDec = null;
            try
            {
                cltDec = new AesCtrCipher(cltDecKey, cltDecIv);
                cltEnc = new AesCtrCipher(cltEncKey, cltEncIv);
                byte[] skip64 = new byte[64];
                cltDec.UpdateInPlace(skip64, 0, 64);

                tgEnc = new AesCtrCipher(relayEncKey, relayEncIv);
                tgDec = new AesCtrCipher(relayDecKey, relayDecIv);
                tgEnc.UpdateInPlace(skip64, 0, 64);

                return new CryptoCtx(cltDec, cltEnc, tgEnc, tgDec);
            }
            catch
            {
                if (cltDec != null) cltDec.Dispose();
                if (cltEnc != null) cltEnc.Dispose();
                if (tgEnc != null) tgEnc.Dispose();
                if (tgDec != null) tgDec.Dispose();
                throw;
            }
        }

        private async Task BridgeWsAsync(
            NetworkStream cltStream, RawWebSocket ws, CryptoCtx ctx, MsgSplitter splitter, CancellationToken ct)
        {
            _activeWs.TryAdd(ws, 0);
            CancellationTokenRegistration ctr = RegisterCancelSafe(ct, delegate
            {
                try { ws.CloseTransport(); } catch { }
                try { cltStream.Close(); } catch { }
            });
            int upWriteFailed = 0;
            try
            {
                Task upTask = Task.Run(async delegate
                {
                    byte[] buf = new byte[65536];
                    bool sendingToWs = false;
                    try
                    {
                        while (!ct.IsCancellationRequested)
                        {
                            int n = await cltStream.ReadAsync(buf, 0, buf.Length).ConfigureAwait(false);
                            if (n <= 0)
                            {
                                if (splitter != null)
                                {
                                    byte[] tail = splitter.Flush();
                                    if (tail != null && tail.Length > 0)
                                    {
                                        sendingToWs = true;
                                        await ws.SendBinaryAsync(tail, ct).ConfigureAwait(false);
                                        sendingToWs = false;
                                    }
                                }
                                break;
                            }
                            if (splitter != null)
                            {
                                byte[] plain = ctx.CltDec.Update(buf, 0, n);
                                byte[] reenc = ctx.TgEnc.Update(plain, 0, plain.Length);
                                List<byte[]> parts = splitter.Split(reenc, plain);
                                if (parts.Count == 1)
                                {
                                    sendingToWs = true;
                                    await ws.SendBinaryAsync(parts[0], ct).ConfigureAwait(false);
                                    sendingToWs = false;
                                }
                                else if (parts.Count > 1)
                                {
                                    sendingToWs = true;
                                    await ws.SendBatchAsync(parts, ct).ConfigureAwait(false);
                                    sendingToWs = false;
                                }
                            }
                            else
                            {
                                ctx.CltDec.UpdateInPlace(buf, 0, n);
                                ctx.TgEnc.UpdateInPlace(buf, 0, n);
                                byte[] chunk = new byte[n];
                                Buffer.BlockCopy(buf, 0, chunk, 0, n);
                                sendingToWs = true;
                                await ws.SendBinaryAsync(chunk, ct).ConfigureAwait(false);
                                sendingToWs = false;
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        if (sendingToWs)
                            Interlocked.Exchange(ref upWriteFailed, 1);
                        if (Verbose && !(ex is OperationCanceledException))
                            Log("DEBUG", "BridgeWs upTask ended: " + ex.Message);
                    }
                });

                Task downTask = Task.Run(async delegate
                {
                    try
                    {
                        while (!ct.IsCancellationRequested)
                        {
                            byte[] frame = await ws.ReceiveAsync(ct).ConfigureAwait(false);
                            if (frame == null)
                                break;
                            if (frame.Length == 0)
                                continue;
                            ctx.TgDec.UpdateInPlace(frame, 0, frame.Length);
                            ctx.CltEnc.UpdateInPlace(frame, 0, frame.Length);
                            await cltStream.WriteAsync(frame, 0, frame.Length).ConfigureAwait(false);
                            await cltStream.FlushAsync().ConfigureAwait(false);
                        }
                    }
                    catch (Exception ex)
                    {
                        if (Verbose && !(ex is OperationCanceledException))
                            Log("DEBUG", "BridgeWs downTask ended: " + ex.Message);
                    }
                });

                Task first = await Task.WhenAny(upTask, downTask).ConfigureAwait(false);
                if (first == upTask && !downTask.IsCompleted && Volatile.Read(ref upWriteFailed) == 0 && _running && !ct.IsCancellationRequested)
                {
                    // Allow brief drain of server responses on TCP half-close from client
                    try { await Task.WhenAny(downTask, Task.Delay(1200, ct)).ConfigureAwait(false); } catch { }
                }
                try { ws.CloseTransport(); } catch { }
                try { cltStream.Close(); } catch { }
                // Ensure both tasks fully exit before disposing ws and before caller disposes CryptoCtx
                try { await Task.WhenAll(upTask, downTask).ConfigureAwait(false); } catch { }
                try { ws.Dispose(); } catch { }
            }
            finally
            {
                try { ctr.Dispose(); } catch { }
                byte removedWs;
                _activeWs.TryRemove(ws, out removedWs);
            }
        }

        private async Task BridgeTcpFallbackAsync(
            NetworkStream cltStream, string dstIp, int port, byte[] relayInit, CryptoCtx ctx, CancellationToken ct)
        {
            IPAddress parsedIp;
            using (TcpClient remote = RawWebSocket.CreateTcpClientForTarget(dstIp, out parsedIp))
            {
                remote.NoDelay = true;
                RawWebSocket.EnableTcpKeepAlive(remote);
                _activeFallbackTcp.TryAdd(remote, 0);
                CancellationTokenRegistration ctr = RegisterCancelSafe(ct, delegate
                {
                    try { remote.Close(); } catch { }
                    try { cltStream.Close(); } catch { }
                });
                try
                {
                    try
                    {
                        Task connectTask = parsedIp != null
                            ? remote.ConnectAsync(parsedIp, port)
                            : remote.ConnectAsync(dstIp, port);
                        await TaskTimeoutHelper.WaitWithTimeoutAsync(
                            connectTask,
                            3500,
                            "TCP fallback connect timeout",
                            delegate { remote.Close(); },
                            ct).ConfigureAwait(false);
                    }
                    catch (System.TimeoutException)
                    {
                        return;
                    }
                    catch (OperationCanceledException)
                    {
                        return;
                    }

                    NetworkStream remStream = remote.GetStream();
                    remStream.WriteTimeout = 30000;
                    cltStream.WriteTimeout = 30000;

                    await TaskTimeoutHelper.WaitWithTimeoutAsync(
                        remStream.WriteAsync(relayInit, 0, relayInit.Length),
                        30000,
                        "TCP fallback init write timeout",
                        delegate { try { remote.Close(); } catch { } },
                        ct).ConfigureAwait(false);
                    await TaskTimeoutHelper.WaitWithTimeoutAsync(
                        remStream.FlushAsync(),
                        30000,
                        "TCP fallback init flush timeout",
                        delegate { try { remote.Close(); } catch { } },
                        ct).ConfigureAwait(false);

                    int upWriteFailed = 0;
                    Task up = Task.Run(async delegate
                    {
                        byte[] b = new byte[65536];
                        bool sendingToRem = false;
                        try
                        {
                            while (!ct.IsCancellationRequested)
                            {
                                int n = await cltStream.ReadAsync(b, 0, b.Length).ConfigureAwait(false);
                                if (n <= 0) break;
                                ctx.CltDec.UpdateInPlace(b, 0, n);
                                ctx.TgEnc.UpdateInPlace(b, 0, n);
                                sendingToRem = true;
                                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                    remStream.WriteAsync(b, 0, n),
                                    30000,
                                    "TCP fallback upstream write timeout",
                                    delegate { try { remote.Close(); } catch { } },
                                    ct).ConfigureAwait(false);
                                sendingToRem = false;
                            }
                        }
                        catch (Exception ex)
                        {
                            if (sendingToRem)
                                Interlocked.Exchange(ref upWriteFailed, 1);
                            if (Verbose && !(ex is OperationCanceledException))
                                Log("DEBUG", "BridgeTcpFallback up ended: " + ex.Message);
                        }
                    });

                    Task down = Task.Run(async delegate
                    {
                        byte[] b = new byte[65536];
                        try
                        {
                            while (!ct.IsCancellationRequested)
                            {
                                int n = await remStream.ReadAsync(b, 0, b.Length).ConfigureAwait(false);
                                if (n <= 0) break;
                                ctx.TgDec.UpdateInPlace(b, 0, n);
                                ctx.CltEnc.UpdateInPlace(b, 0, n);
                                await TaskTimeoutHelper.WaitWithTimeoutAsync(
                                    cltStream.WriteAsync(b, 0, n),
                                    30000,
                                    "TCP fallback client write timeout",
                                    delegate { try { cltStream.Close(); } catch { } },
                                    ct).ConfigureAwait(false);
                            }
                        }
                        catch (Exception ex)
                        {
                            if (Verbose && !(ex is OperationCanceledException))
                                Log("DEBUG", "BridgeTcpFallback down ended: " + ex.Message);
                        }
                    });

                    Task first = await Task.WhenAny(up, down).ConfigureAwait(false);
                    if (first == up && !down.IsCompleted && Volatile.Read(ref upWriteFailed) == 0 && _running && !ct.IsCancellationRequested)
                    {
                        try { await Task.WhenAny(down, Task.Delay(800, ct)).ConfigureAwait(false); } catch { }
                    }
                    try { remStream.Close(); } catch { }
                    try { cltStream.Close(); } catch { }
                    try { await Task.WhenAll(up, down).ConfigureAwait(false); } catch { }
                }
                finally
                {
                    try { ctr.Dispose(); } catch { }
                    byte removedRem;
                    _activeFallbackTcp.TryRemove(remote, out removedRem);
                }
            }
        }

        public async Task<int> RunHealthCheckAsync()
        {
            FinalizeConfig();
            Console.WriteLine("========================================================================");
            Console.WriteLine("  Zapret2 TG WS Proxy Connectivity & DC Health Check");
            Console.WriteLine("========================================================================");
            bool directOk = false;
            bool cfWssOk = false;
            bool cfWs80Ok = false;

            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                directOk = await EnsureDirectWsProbedAsync(CancellationToken.None).ConfigureAwait(false);
                if (directOk)
                {
                    Console.WriteLine(string.Format("  [OK] Direct Telegram WS ({0}): {1} ms", _workingDirectIp, sw.ElapsedMilliseconds));
                }
                else
                {
                    Console.WriteLine("  [i] Direct Telegram WS IPs (149.154.167.220 / 91.108.56.130) blocked by ISP at TCP SYN.");
                    Console.WriteLine("      -> Instant Circuit-Breaker active (0 ms delay, routes via Cloudflare Clean-IP).");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("  [i] Direct Telegram WS probe failed: " + ex.Message);
            }

            if (_cfDomains.Count > 0)
            {
                sw.Restart();
                try
                {
                    CfRouteSpec wssSpec = new CfRouteSpec(CleanCfAnycastIps[0], 443, true, null, _cfDomains[0], "cf-clean-wss");
                    using (RawWebSocket wsWss = await ConnectViaSpecAsync(2, wssSpec, 3200, CancellationToken.None).ConfigureAwait(false))
                    {
                        cfWssOk = true;
                        Console.WriteLine(string.Format("  [OK] Cloudflare Clean-IP WSS :443 ({0}): {1} ms", wsWss.RouteLabel, sw.ElapsedMilliseconds));
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  [!] Cloudflare Clean-IP WSS :443 failed: " + ex.Message);
                }

                sw.Restart();
                try
                {
                    CfRouteSpec ws80Spec = new CfRouteSpec(CleanCfAnycastIps[0], 80, false, null, _cfDomains[0], "cf-clean-ws80");
                    using (RawWebSocket ws80 = await ConnectViaSpecAsync(2, ws80Spec, 3200, CancellationToken.None).ConfigureAwait(false))
                    {
                        cfWs80Ok = true;
                        Console.WriteLine(string.Format("  [OK] Cloudflare Clean-IP HTTP WS :80 ({0}): {1} ms", ws80.RouteLabel, sw.ElapsedMilliseconds));
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  [!] Cloudflare Clean-IP HTTP WS :80 failed: " + ex.Message);
                }

                if (!cfWssOk && !cfWs80Ok)
                {
                    sw.Restart();
                    try
                    {
                        using (RawWebSocket wsRace = await RaceCfRoutesAsync(2, 4000, CancellationToken.None).ConfigureAwait(false))
                        {
                            if (wsRace != null)
                            {
                                cfWssOk = true;
                                Console.WriteLine(string.Format("  [OK] Cloudflare Multi-Route Winner ({0}): {1} ms", wsRace.RouteLabel, sw.ElapsedMilliseconds));
                            }
                        }
                    }
                    catch { }
                }
            }

            Console.WriteLine("------------------------------------------------------------------------");
            if (directOk || cfWssOk || cfWs80Ok)
            {
                Console.WriteLine("  Result: READY! Telegram will connect without WARP in Smart & CF modes.");
            }
            else
            {
                Console.WriteLine("  Warning: All routes timed out. Make sure zapret service (Option 1) is running!");
            }
            Console.WriteLine("========================================================================");
            return (directOk || cfWssOk || cfWs80Ok) ? 0 : 1;
        }

        public static bool IsValidHex32(string hex)
        {
            if (string.IsNullOrEmpty(hex) || hex.Length != 32)
                return false;
            for (int i = 0; i < 32; i++)
            {
                char c = hex[i];
                bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
                if (!ok) return false;
            }
            return true;
        }

        public static byte[] HexToBytes(string hex)
        {
            byte[] bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return bytes;
        }

        public static string BytesToHex(byte[] bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length * 2);
            for (int i = 0; i < bytes.Length; i++)
                sb.Append(bytes[i].ToString("x2"));
            return sb.ToString();
        }
    }

    internal sealed class TgWsWindowsService : ServiceBase
    {
        private readonly TgWsProxyEngine _engine;

        public TgWsWindowsService(TgWsProxyEngine engine)
        {
            ServiceName = "zapret-tgws";
            CanStop = true;
            CanShutdown = true;
            CanPauseAndContinue = false;
            AutoLog = false;
            _engine = engine;
        }

        protected override void OnStart(string[] args)
        {
            try
            {
                _engine.Start();
            }
            catch (Exception ex)
            {
                try { _engine.Log("ERROR", "Service failed to start: " + ex.ToString()); } catch { }
                throw;
            }
        }

        protected override void OnStop()
        {
            _engine.Stop();
        }

        protected override void OnShutdown()
        {
            _engine.Stop();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { _engine.Dispose(); } catch { }
            }
            base.Dispose(disposing);
        }
    }

    internal static class Program
    {
        private static int Main(string[] args)
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string rootDir = Path.GetFullPath(Path.Combine(exeDir, ".."));
            string defaultConf = Path.Combine(rootDir, "utils", "tgws_proxy.conf");
            string defaultLog = Path.Combine(exeDir, "logs", "tg-ws-proxy.log");

            string customConf = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--config")
                {
                    if (i + 1 >= args.Length)
                    {
                        Console.Error.WriteLine("[ERROR] Missing value for --config");
                        return 2;
                    }
                    customConf = args[++i];
                }
            }

            using (TgWsProxyEngine engine = new TgWsProxyEngine())
            {
                engine.LogFile = defaultLog;

                bool forceService = false;
                bool forceConsole = false;
                bool healthCheck = false;

                try
                {
                    if (customConf != null)
                    {
                        if (string.IsNullOrWhiteSpace(customConf) || !File.Exists(customConf))
                            throw new FileNotFoundException("Config file not found: " + customConf, customConf);
                        engine.LoadConfigFile(customConf);
                    }
                    else
                    {
                        engine.LoadConfigFile(defaultConf);
                    }

                    for (int i = 0; i < args.Length; i++)
                    {
                        string a = args[i];
                        if (a == "--service") forceService = true;
                        else if (a == "--console") forceConsole = true;
                        else if (a == "--health-check" || a == "--test-dc") healthCheck = true;
                        else if (a == "-v" || a == "--verbose") engine.Verbose = true;
                        else if (a == "--no-cfproxy") engine.FallbackCfProxy = false;
                        else if (a == "--no-secure") engine.DisableSecure = true;
                        else if (a == "--config") { i++; }
                        else if (a == "--host")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --host");
                            engine.Host = args[++i];
                        }
                        else if (a == "--port")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --port");
                            engine.SetPortFromText(args[++i]);
                        }
                        else if (a == "--secret")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --secret");
                            engine.SecretHex = args[++i].Trim();
                        }
                        else if (a == "--mode")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --mode");
                            engine.Mode = args[++i].Trim().ToLowerInvariant();
                        }
                        else if (a == "--pool-size")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --pool-size");
                            string psRaw = args[++i];
                            int ps;
                            if (!int.TryParse(psRaw, out ps) || ps < 0)
                                throw new ArgumentException("Invalid --pool-size value: " + psRaw);
                            engine.PoolSize = ps;
                        }
                        else if (a == "--log-file")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --log-file");
                            engine.LogFile = args[++i];
                        }
                        else if (a == "--cfproxy-domain")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --cfproxy-domain");
                            foreach (string d in args[++i].Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                                TgWsProxyEngine.AddUniqueDomain(engine.CfUserDomains, d);
                        }
                        else if (a == "--cfproxy-worker-domain")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --cfproxy-worker-domain");
                            foreach (string d in args[++i].Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                                TgWsProxyEngine.AddUniqueDomain(engine.CfWorkerDomains, d);
                        }
                        else if (a == "--dc-ip")
                        {
                            if (i + 1 >= args.Length) throw new ArgumentException("Missing value for --dc-ip");
                            string dcIp = args[++i];
                            int colon = dcIp.IndexOf(':');
                            int dcNum;
                            if (colon <= 0 || !int.TryParse(dcIp.Substring(0, colon), out dcNum) || !engine.AddUserDcRedirect(dcNum, dcIp.Substring(colon + 1)))
                                throw new ArgumentException("Invalid --dc-ip value (expected DC:IP): " + dcIp);
                        }
                    }

                    if (healthCheck)
                        engine.LogFile = "";

                    engine.FinalizeConfig();
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("[ERROR] Configuration error: " + ex.Message);
                    return 2;
                }

                if (healthCheck)
                {
                    return engine.RunHealthCheckAsync().GetAwaiter().GetResult();
                }

                if (forceService || (!Environment.UserInteractive && !forceConsole))
                {
                    using (TgWsWindowsService svc = new TgWsWindowsService(engine))
                    {
                        ServiceBase.Run(svc);
                    }
                    return 0;
                }

                engine.Start();
                Console.WriteLine("Press Ctrl+C to stop...");
                using (ManualResetEvent quitEvent = new ManualResetEvent(false))
                {
                    ConsoleCancelEventHandler cancelHandler = delegate(object sender, ConsoleCancelEventArgs e)
                    {
                        e.Cancel = true;
                        try { quitEvent.Set(); } catch { }
                    };
                    Console.CancelKeyPress += cancelHandler;
                    try
                    {
                        quitEvent.WaitOne();
                    }
                    finally
                    {
                        Console.CancelKeyPress -= cancelHandler;
                    }
                }
                engine.Stop();
                return 0;
            }
        }
    }
}
