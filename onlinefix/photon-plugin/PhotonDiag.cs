// Photon Diagnostics: a BepInEx plugin that changes nothing.
//
// It logs what a Unity game actually asks Photon for, so a fix can be written
// against facts instead of guesses: the app id and version, the region, the
// AuthenticationValues (auth type, user id, token, auth parameters), the ticket
// handed to Photon, every connection status, and the exact error Photon returns.
//
// It is reflection-only: no Photon assembly is referenced, so the same DLL loads
// in any PUN1/PUN2 game. Every hook is wrapped, and a missing type or method is
// logged and skipped, never thrown into the game.
using System;
using System.IO;
using System.Reflection;
using System.Text;
using BepInEx;
using BepInEx.Logging;
using HarmonyLib;

namespace PhotonDiag
{
    [BepInPlugin(PluginGuid, PluginName, PluginVersion)]
    public sealed class PhotonDiagPlugin : BaseUnityPlugin
    {
        public const string PluginGuid = "macsteam.photon.diagnostics";
        public const string PluginName = "Photon Diagnostics";
        public const string PluginVersion = "1.0.0";

        internal static ManualLogSource Log;
        private static string _file;
        private static readonly object Gate = new object();

        private void Awake()
        {
            Log = Logger;
            try { _file = Path.Combine(Paths.GameRootPath, "PhotonDiag.log"); }
            catch { _file = null; }

            Write("PhotonDiag " + PluginVersion + " loaded, game root " + Paths.GameRootPath);
            try { DumpSettings(); } catch (Exception e) { Write("settings dump failed: " + e.Message); }
            try { Patcher.PatchAll(new Harmony(PluginGuid)); }
            catch (Exception e) { Write("patching failed: " + e.Message); }
        }

        internal static void Write(string message)
        {
            var line = DateTime.Now.ToString("HH:mm:ss.fff") + " " + message;
            try { Log.LogInfo(message); } catch { }
            if (_file == null) return;
            try
            {
                lock (Gate) { File.AppendAllText(_file, line + Environment.NewLine, Encoding.UTF8); }
            }
            catch { }
        }

        /// <summary>The configured app ids and version, before anything connects.</summary>
        private static void DumpSettings()
        {
            // PUN2 keeps them on Photon.Realtime.PhotonAppSettings.Global.
            var holder = AccessTools.TypeByName("Photon.Realtime.PhotonAppSettings");
            if (holder != null)
            {
                var global = AccessTools.Property(holder, "Global") != null
                    ? AccessTools.Property(holder, "Global").GetValue(null, null)
                    : null;
                var settings = global != null ? Get(global, "AppSettings") : null;
                if (settings != null) { DumpAppSettings("PUN2", settings); return; }
            }

            // PUN1 keeps them on PhotonNetwork.PhotonServerSettings.
            var network = AccessTools.TypeByName("PhotonNetwork");
            if (network != null)
            {
                var server = AccessTools.Property(network, "PhotonServerSettings") != null
                    ? AccessTools.Property(network, "PhotonServerSettings").GetValue(null, null)
                    : null;
                var settings = server != null ? Get(server, "AppSettings") : server;
                if (settings != null) { DumpAppSettings("PUN1", settings); return; }
            }
            Write("no Photon settings found (the game may not have initialised Photon yet)");
        }

        private static void DumpAppSettings(string flavour, object settings)
        {
            Write(flavour + " app settings:");
            foreach (var name in new[]
            {
                "AppIdRealtime", "AppIdFusion", "AppIdChat", "AppIdVoice", "AppVersion",
                "FixedRegion", "UseNameServer", "Server", "Port", "Protocol",
            })
            {
                var value = Get(settings, name);
                if (value != null) Write("  " + name + " = " + value);
            }
        }

        internal static object Get(object target, string property)
        {
            if (target == null) return null;
            try
            {
                var type = target.GetType();
                var prop = AccessTools.Property(type, property);
                if (prop != null) return prop.GetValue(target, null);
                var field = AccessTools.Field(type, property);
                return field != null ? field.GetValue(target) : null;
            }
            catch { return null; }
        }

        internal static string Describe(object value)
        {
            if (value == null) return "null";
            if (value is string s) return "\"" + (s.Length > 64 ? s.Substring(0, 64) + "…" : s) + "\"";
            if (value is byte[] bytes) return "byte[" + bytes.Length + "]";
            return value.GetType().Name + " " + value;
        }
    }

    internal static class Patcher
    {
        private static Harmony _harmony;

        internal static void PatchAll(Harmony harmony)
        {
            _harmony = harmony;
            // PUN2 authenticates here; PUN1 uses OpAuthenticateOnce.
            Patch("Photon.Realtime.LoadBalancingClient", "OpAuthenticate", "OnAuthenticate");
            Patch("Photon.Realtime.LoadBalancingClient", "OpAuthenticateOnce", "OnAuthenticate");
            Patch("Photon.Realtime.LoadBalancingClient", "ConnectToRegionMaster", "OnConnectToRegion");
            Patch("Photon.Realtime.LoadBalancingClient", "OnStatusChanged", "OnStatus");
            Patch("Photon.Realtime.LoadBalancingClient", "OnOperationResponse", "OnOperation");
            Patch("Photon.Realtime.LoadBalancingClient", "OnError", "OnError");
            Patch("Photon.Realtime.LoadBalancingClient", "OnDisconnected", "OnDisconnected");
            Patch("Photon.Realtime.LoadBalancingClient", "DebugReturn", "OnDebugReturn");
            // PUN1 keeps PhotonNetwork at the root; PUN2 namespaces it.
            Patch("OnConnectUsingSettings", "ConnectUsingSettings",
                  "PhotonNetwork", "Photon.Pun.PhotonNetwork");
        }

        private static void Patch(string typeName, string methodName, string handler)
        {
            Patch(handler, methodName, typeName);
        }

        /// <summary>Patches the first of several possible type names that exists.</summary>
        private static void Patch(string handler, string methodName, params string[] typeNames)
        {
            foreach (var candidate in typeNames)
            {
                if (AccessTools.TypeByName(candidate) == null) continue;
                PatchOne(candidate, methodName, handler);
                return;
            }
            PhotonDiagPlugin.Write("skip " + string.Join("/", typeNames) + "." + methodName + ": type not found");
        }

        private static void PatchOne(string typeName, string methodName, string handler)
        {
            try
            {
                var type = AccessTools.TypeByName(typeName);
                var method = Find(type, methodName);
                if (method == null) { PhotonDiagPlugin.Write("skip " + typeName + "." + methodName + ": method not found"); return; }
                var prefix = new HarmonyMethod(typeof(Patcher).GetMethod(handler, BindingFlags.Static | BindingFlags.NonPublic));
                _harmony.Patch(method, prefix: prefix);
                PhotonDiagPlugin.Write("hooked " + typeName + "." + methodName);
            }
            catch (Exception e)
            {
                PhotonDiagPlugin.Write("skip " + typeName + "." + methodName + ": " + e.Message);
            }
        }

        private static MethodInfo Find(Type type, string name)
        {
            foreach (var method in type.GetMethods(BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
            {
                if (method.Name == name) return method;
            }
            return null;
        }

        // Every handler takes the target instance and its raw arguments, so one
        // signature fits every Photon version.
        private static void OnAuthenticate(object __instance, object[] __args)
        {
            try
            {
                PhotonDiagPlugin.Write("OpAuthenticate:");
                for (var i = 0; i < __args.Length; i++)
                {
                    var value = __args[i];
                    if (value == null) continue;
                    var name = value.GetType().Name;
                    if (name == "AuthenticationValues")
                    {
                        PhotonDiagPlugin.Write("  auth type = " + PhotonDiagPlugin.Get(value, "AuthType"));
                        PhotonDiagPlugin.Write("  user id   = " + PhotonDiagPlugin.Describe(PhotonDiagPlugin.Get(value, "UserId")));
                        var token = PhotonDiagPlugin.Get(value, "Token");
                        PhotonDiagPlugin.Write("  token     = " + (token == null ? "null" : token.GetType().Name + " " + PhotonDiagPlugin.Describe(token)));
                        var parameters = PhotonDiagPlugin.Get(value, "AuthGetParameters");
                        if (parameters != null)
                        {
                            var dict = parameters as System.Collections.IDictionary;
                            if (dict != null)
                            {
                                foreach (System.Collections.DictionaryEntry entry in dict)
                                    PhotonDiagPlugin.Write("  auth param " + entry.Key + " = " + PhotonDiagPlugin.Describe(entry.Value));
                            }
                        }
                    }
                    else if (value is string text)
                    {
                        PhotonDiagPlugin.Write("  arg[" + i + "] = \"" + text + "\"");
                    }
                    else if (value is byte[] bytes)
                    {
                        PhotonDiagPlugin.Write("  arg[" + i + "] = byte[" + bytes.Length + "]");
                    }
                    else
                    {
                        PhotonDiagPlugin.Write("  arg[" + i + "] = " + name);
                    }
                }
            }
            catch (Exception e) { PhotonDiagPlugin.Write("auth log failed: " + e.Message); }
        }

        private static void OnConnectToRegion(object[] __args)
        {
            try
            {
                PhotonDiagPlugin.Write("ConnectToRegionMaster: " + (__args.Length > 0 ? PhotonDiagPlugin.Describe(__args[0]) : "?"));
            }
            catch { }
        }

        private static void OnConnectUsingSettings(object[] __args)
        {
            try
            {
                PhotonDiagPlugin.Write("PhotonNetwork.ConnectUsingSettings (" + __args.Length + " args)");
            }
            catch { }
        }

        private static void OnStatus(object[] __args)
        {
            try
            {
                PhotonDiagPlugin.Write("status: " + (__args.Length > 0 ? __args[0].ToString() : "?"));
            }
            catch { }
        }

        private static void OnOperation(object[] __args)
        {
            try
            {
                if (__args.Length == 0 || __args[0] == null) return;
                var response = __args[0];
                var code = PhotonDiagPlugin.Get(response, "OperationCode");
                var result = PhotonDiagPlugin.Get(response, "ReturnCode");
                var message = PhotonDiagPlugin.Get(response, "DebugMessage");
                PhotonDiagPlugin.Write("response op=" + code + " return=" + result
                    + (message == null ? "" : " \"" + message + "\""));
            }
            catch { }
        }

        private static void OnError(object[] __args)
        {
            try
            {
                var parts = new string[__args.Length];
                for (var i = 0; i < __args.Length; i++) parts[i] = PhotonDiagPlugin.Describe(__args[i]);
                PhotonDiagPlugin.Write("error: " + string.Join(", ", parts));
            }
            catch { }
        }

        private static void OnDisconnected(object[] __args)
        {
            try
            {
                PhotonDiagPlugin.Write("disconnected: " + (__args.Length > 0 ? PhotonDiagPlugin.Describe(__args[0]) : "?"));
            }
            catch { }
        }

        private static void OnDebugReturn(object[] __args)
        {
            try
            {
                if (__args.Length < 2) return;
                var level = __args[0] == null ? "" : __args[0].ToString();
                var text = __args[1] as string;
                if (string.IsNullOrEmpty(text)) return;
                // Photon is chatty; only the lines that name a failure are worth a file.
                if (text.IndexOf("error", StringComparison.OrdinalIgnoreCase) >= 0
                    || text.IndexOf("fail", StringComparison.OrdinalIgnoreCase) >= 0
                    || text.IndexOf("auth", StringComparison.OrdinalIgnoreCase) >= 0
                    || text.IndexOf("connect", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    PhotonDiagPlugin.Write("photon[" + level + "] " + text);
                }
            }
            catch { }
        }
    }
}
