// Windows PowerShell 5.1 / .NET Framework 4.8. No third-party runtime.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Caelestia.Update {
    public static class Transport {
        public static void ValidateUri(Uri uri, string[] hosts) {
            if (!uri.IsAbsoluteUri || uri.Scheme != "https" || uri.Port != 443 ||
                uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.IsUnc ||
                Array.IndexOf(hosts, uri.Host) < 0) throw new FormatException("Unsafe update URI.");
        }
        // One cancellation deadline covers DNS/connect, every redirect and body.
        // No global TLS, certificate validation or OS security settings changed.
        public static byte[] Fetch(string address, string[] hosts, int redirects, long cap,
                                  long expectedSize, string hash, string destination, int milliseconds) {
            if (cap < 1 || cap > 1073741824 || milliseconds < 1 || milliseconds > 1800000)
                throw new FormatException("Invalid transport bounds.");
            using (var cancel = new CancellationTokenSource(milliseconds))
            using (var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false,
                UseDefaultCredentials = false, AutomaticDecompression = DecompressionMethods.None })
            using (var client = new HttpClient(handler)) {
                client.Timeout = Timeout.InfiniteTimeSpan;
                Uri uri = new Uri(address, UriKind.Absolute);
                for (int hop = 0; ; hop++) {
                    ValidateUri(uri, hosts);
                    using (var request = new HttpRequestMessage(HttpMethod.Get, uri))
                    using (var response = client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead,
                                                          cancel.Token).GetAwaiter().GetResult()) {
                        int status = (int)response.StatusCode;
                        if (status >= 300 && status < 400) {
                            if (hop >= redirects || response.Headers.Location == null)
                                throw new IOException("Update redirect refused.");
                            uri = new Uri(uri, response.Headers.Location); continue;
                        }
                        if (status != 200) throw new IOException("Update HTTP failure.");
                        using (var input = response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
                        using (Stream output = string.IsNullOrEmpty(destination) ? (Stream)new MemoryStream() :
                            new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                            CopyBounded(input, output, cap, expectedSize, hash, cancel.Token);
                            if (string.IsNullOrEmpty(destination)) return ((MemoryStream)output).ToArray();
                            return null;
                        }
                    }
                }
            }
        }
        public static void CopyBounded(Stream input, Stream output, long cap, long expectedSize,
                                       string expectedHash, CancellationToken token) {
            using (var sha = SHA256.Create()) {
                byte[] buffer = new byte[65536]; long total = 0;
                while (true) {
                    int count = input.ReadAsync(buffer, 0, buffer.Length, token).GetAwaiter().GetResult();
                    if (count == 0) break;
                    total = checked(total + count);
                    if (total > cap) throw new IOException("Update body exceeds bound.");
                    sha.TransformBlock(buffer, 0, count, null, 0);
                    output.Write(buffer, 0, count);
                }
                token.ThrowIfCancellationRequested();
                sha.TransformFinalBlock(new byte[0], 0, 0);
                if (expectedSize >= 0 && total != expectedSize) throw new IOException("Update body size mismatch.");
                string hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                if (!string.IsNullOrEmpty(expectedHash) && hash != expectedHash) throw new IOException("Update body hash mismatch.");
            }
        }
    }
    public static class Security {
        public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        public static string Hash(byte[] value) {
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(value)).Replace("-", "").ToLowerInvariant();
        }
        public static byte[] Pae(string type, byte[] payload) {
            byte[] t = Utf8.GetBytes(type);
            byte[] a = Encoding.ASCII.GetBytes("DSSEv1 " + t.Length.ToString(CultureInfo.InvariantCulture) + " ");
            byte[] b = Encoding.ASCII.GetBytes(" " + payload.Length.ToString(CultureInfo.InvariantCulture) + " ");
            using (var stream = new MemoryStream()) {
                stream.Write(a, 0, a.Length); stream.Write(t, 0, t.Length);
                stream.Write(b, 0, b.Length); stream.Write(payload, 0, payload.Length);
                return stream.ToArray();
            }
        }
        public static byte[] Base64(string value) {
            // Convert.FromBase64String alone accepts whitespace.
            byte[] result = Convert.FromBase64String(value);
            if (Convert.ToBase64String(result) != value) throw new FormatException("Noncanonical base64.");
            return result;
        }
        public static string KeyId(byte[] x, byte[] y) {
            if (x.Length != 32 || y.Length != 32) throw new FormatException("Invalid P256 coordinates.");
            using (var stream = new MemoryStream()) {
                byte[] prefix = Encoding.ASCII.GetBytes("caelestia-ecdsa-p256:");
                stream.Write(prefix, 0, prefix.Length); stream.Write(x, 0, 32); stream.Write(y, 0, 32);
                return Hash(stream.ToArray());
            }
        }
        public static bool Verify(byte[] data, byte[] signature, byte[] x, byte[] y) {
            if (signature.Length != 64 || x.Length != 32 || y.Length != 32) return false;
            // BCRYPT_ECCPUBLIC_BLOB, ECDSA public P256 magic ECS1, cbKey=32.
            // CNG avoids modern-only ECParameters/ImportSubjectPublicKeyInfo APIs.
            byte[] blob = new byte[72];
            blob[0] = 0x45; blob[1] = 0x43; blob[2] = 0x53; blob[3] = 0x31; blob[4] = 32;
            Buffer.BlockCopy(x, 0, blob, 8, 32); Buffer.BlockCopy(y, 0, blob, 40, 32);
            using (CngKey key = CngKey.Import(blob, CngKeyBlobFormat.EccPublicBlob))
            using (var ecdsa = new ECDsaCng(key))
                return ecdsa.VerifyData(data, signature, HashAlgorithmName.SHA256);
        }
        public static byte[] Sign(byte[] data, byte[] pkcs8) {
            using (CngKey key = CngKey.Import(pkcs8, CngKeyBlobFormat.Pkcs8PrivateBlob))
            using (var ecdsa = new ECDsaCng(key)) {
                if (ecdsa.KeySize != 256) throw new FormatException("Only P256 is supported.");
                byte[] signature = ecdsa.SignData(data, HashAlgorithmName.SHA256);
                if (signature.Length != 64) throw new FormatException("Expected P1363 signature.");
                return signature;
            }
        }
        public static object Json(byte[] bytes) {
            return Json(bytes, 65536);
        }
        public static object Json(byte[] bytes, int maxBytes) {
            if (maxBytes < 1 || maxBytes > 16777216 || bytes.Length > maxBytes)
                throw new FormatException("JSON exceeds byte bound.");
            return new StrictJson(Utf8.GetString(bytes)).Read();
        }
        public static object JsonFile(string path, int maxBytes) {
            return JsonFile(path, maxBytes, false);
        }
        public static object JsonFile(string path, int maxBytes, bool allowUtf8Bom) {
            if (maxBytes < 1 || maxBytes > 16777216) throw new FormatException("Invalid JSON bound.");
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var output = new MemoryStream()) {
                if (input.Length < 1 || input.Length > maxBytes) throw new FormatException("JSON exceeds byte bound.");
                Transport.CopyBounded(input, output, maxBytes, input.Length, null, CancellationToken.None);
                byte[] bytes = output.ToArray();
                // Existing release.json uses PowerShell 5.1 Set-Content UTF8
                // (BOM). Its *original bytes* were already hashed. Network
                // DSSE/keys/channel documents never use this compatibility path.
                if (allowUtf8Bom && bytes.Length >= 3 &&
                    bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191) {
                    byte[] withoutBom = new byte[bytes.Length - 3];
                    Buffer.BlockCopy(bytes, 3, withoutBom, 0, withoutBom.Length);
                    bytes = withoutBom;
                }
                return Json(bytes, maxBytes);
            }
        }
    }

    // Security documents need more than ConvertFrom-Json: duplicate and
    // case-conflicting names, invalid UTF8, unpaired surrogates, trailing input,
    // exponent/float coercion and excessive depth are all rejected.
    internal sealed class StrictJson {
        private readonly string text;
        private int position;
        public StrictJson(string value) { text = value; }
        private void White() {
            while (position < text.Length && (text[position] == ' ' || text[position] == '\r' ||
                   text[position] == '\n' || text[position] == '\t')) position++;
        }
        private char Take() {
            if (position >= text.Length) throw new FormatException("Unexpected JSON end.");
            return text[position++];
        }
        private void Expect(char expected) {
            White(); if (Take() != expected) throw new FormatException("Invalid JSON punctuation.");
        }
        public object Read() {
            object result = Value(0); White();
            if (position != text.Length) throw new FormatException("Trailing JSON input.");
            return result;
        }
        private object Value(int depth) {
            if (depth > 24) throw new FormatException("JSON nesting limit.");
            White();
            if (position >= text.Length) throw new FormatException("Missing JSON value.");
            char c = text[position];
            if (c == '"') return String();
            if (c == '{') {
                position++;
                var result = new Dictionary<string, object>(StringComparer.Ordinal);
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                White(); if (position < text.Length && text[position] == '}') { position++; return result; }
                while (true) {
                    White(); string name = String();
                    if (!names.Add(name)) throw new FormatException("Ambiguous JSON field.");
                    Expect(':'); result.Add(name, Value(depth + 1)); White();
                    char next = Take(); if (next == '}') return result;
                    if (next != ',') throw new FormatException("Invalid JSON object.");
                }
            }
            if (c == '[') {
                position++; var result = new List<object>();
                White(); if (position < text.Length && text[position] == ']') { position++; return result.ToArray(); }
                while (true) {
                    result.Add(Value(depth + 1)); White();
                    char next = Take(); if (next == ']') return result.ToArray();
                    if (next != ',') throw new FormatException("Invalid JSON array.");
                }
            }
            foreach (string word in new [] { "true", "false", "null" }) {
                if (text.Substring(position).StartsWith(word, StringComparison.Ordinal)) {
                    position += word.Length;
                    if (word == "null") return null;
                    return word == "true";
                }
            }
            int start = position;
            if (c == '-') position++;
            if (position >= text.Length) throw new FormatException("Invalid JSON number.");
            if (text[position] == '0') position++;
            else {
                if (text[position] < '1' || text[position] > '9') throw new FormatException("Invalid JSON number.");
                while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++;
            }
            long number;
            if (!long.TryParse(text.Substring(start, position - start), NumberStyles.AllowLeadingSign,
                    CultureInfo.InvariantCulture, out number)) throw new FormatException("JSON integer overflow.");
            return number;
        }
        private string String() {
            if (Take() != '"') throw new FormatException("Expected JSON string.");
            var result = new StringBuilder();
            while (true) {
                char c = Take(); if (c == '"') break;
                if (c < 32) throw new FormatException("JSON control character.");
                if (c == '\\') {
                    c = Take();
                    switch (c) {
                        case '"': case '\\': case '/': result.Append(c); break;
                        case 'b': result.Append('\b'); break; case 'f': result.Append('\f'); break;
                        case 'n': result.Append('\n'); break; case 'r': result.Append('\r'); break;
                        case 't': result.Append('\t'); break;
                        case 'u':
                            if (position + 4 > text.Length) throw new FormatException("Truncated JSON escape.");
                            result.Append((char)ushort.Parse(text.Substring(position, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture));
                            position += 4; break;
                        default: throw new FormatException("Invalid JSON escape.");
                    }
                } else result.Append(c);
            }
            string value = result.ToString();
            // Throw on invalid UTF16, including escaped unpaired surrogates.
            Security.Utf8.GetByteCount(value);
            return value;
        }
    }
}
