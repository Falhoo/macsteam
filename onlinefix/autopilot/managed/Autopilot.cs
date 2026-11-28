// Making a game try its own online connection, so the installer can watch the answer.
//
// Patching is only half the job: whether Photon accepts the result depends on the app
// id, the auth type, the region and the account, and nothing on disk records what
// Photon said last time. Clicking the game's menus to find out needs to know where
// every game keeps its Play button.
//
// So the game is asked to connect instead. This runs inside the game's own managed
// runtime, after Unity is up, and calls Photon's own client — the same one the player
// would reach through the menus. Whatever Photon answers is written to
// `macsteam-autopilot.log`, where the installer reads it.
//
// Loaded by MacsteamAutopilot.dll (the native shim), which is loaded from the fix's
// dlllist. Only acts when `macsteam-autopilot.on` is beside the game, so a normal
// launch is untouched.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading;

namespace Macsteam {
    public static class Autopilot {

        static string _folder;
        static string _log;

        /// Entry point, called by the shim on a worker thread. The folder is passed in:
        /// the assembly is loaded from memory, so it has no location of its own.
        public static void Run(string folder) {
            try {
                _folder = folder;
                _log = Path.Combine(_folder, "macsteam-autopilot.log");
                Say("start base=" + _folder + " cwd=" + Directory.GetCurrentDirectory());
                string flag = Path.Combine(_folder, "macsteam-autopilot.on");
                if (!File.Exists(flag)) { Say("not asked for"); return; }

                Type photon = WaitForPhoton(120);
                if (photon == null) { Say("fail no-photon"); return; }
                Say("photon " + photon.Assembly.GetName().Name);

                // The game has to be past its splash screens before Photon will hold a
                // connection, and there is no signal for "the menu is up". Its own clock
                // is the closest thing: the engine has started and been up for a while,
                // which a connect during loading would not be.
                WaitForEngine();
                if (IsOn(photon)) { Say("ok already-connected"); return; }

                Say("settings " + Text(photon, "AppSettings", "PhotonServerSettings", null));
                Set(photon, "NickName", "macSteam");
                Say("connecting");

                // A refusal within the first seconds of an engine can be the game still
                // settling rather than a wrong patch, so it is asked once more.
                string outcome = "";
                for (int attempt = 0; attempt < 2; attempt++) {
                    Invoke(photon, "ConnectUsingSettings", new object[0]);
                    outcome = Follow(photon, 45);
                    Say(outcome);
                    if (outcome.StartsWith("ok")) break;
                    if (outcome.Contains("timeout")) break;
                    if (!EarlyInEngine()) break;
                    Thread.Sleep(TimeSpan.FromSeconds(12));
                    if (IsOn(photon)) { outcome = "ok already-connected"; break; }
                }
                if (!outcome.StartsWith("ok")) return;

                // Leave it as found: a connection held open would block the player's own.
                Thread.Sleep(TimeSpan.FromSeconds(1));
                Invoke(photon, "Disconnect", new object[0]);
                Say("done");
            } catch (Exception e) {
                Say("fail exception " + e.GetType().Name + ": " + e.Message);
            }
        }

        /// How long the engine has to have been running before Photon is touched, in
        /// seconds since the application started. R.E.P.O. and its kind spend a minute
        /// on shaders with a cold cache, and a connect during that is refused.
        static readonly TimeSpan Settle = TimeSpan.FromSeconds(25);
        static readonly TimeSpan SettleWarm = TimeSpan.FromSeconds(8);

        /// Waits on the game's own clock rather than on a guess: a fixed sleep either
        /// wastes time on a warm start or connects too early on a cold one.
        static void WaitForEngine() {
            bool warm = File.Exists(Path.Combine(_folder, "macsteam-autopilot.warm"));
            try { File.WriteAllText(Path.Combine(_folder, "macsteam-autopilot.warm"), "1"); } catch {}
            TimeSpan wanted = warm ? SettleWarm : Settle;
            DateTime deadline = DateTime.UtcNow.AddSeconds(90);
            while (DateTime.UtcNow < deadline) {
                double up = EngineSeconds();
                if (up < 0 || TimeSpan.FromSeconds(up) >= wanted) return;
                Thread.Sleep(500);
            }
        }

        /// `Time.realtimeSinceStartup`, or -1 when this build does not expose it.
        static double EngineSeconds() {
            try {
                Type time = null;
                foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                    if (assembly.GetName().Name != "UnityEngine.CoreModule") continue;
                    time = assembly.GetType("UnityEngine.Time", false);
                    if (time != null) break;
                }
                object value = time == null ? null : Get(time, "realtimeSinceStartup", null);
                return value is float ? (float)value : -1;
            } catch { return -1; }
        }

        static Type WaitForPhoton(int halfSeconds) {
            for (int i = 0; i < halfSeconds; i++) {
                Type found = Find();
                if (found != null) return found;
                Thread.Sleep(500);
            }
            // A game that has not gone online yet has never touched Photon, so its
            // classes are still unloaded. Loading the shipped Photon assemblies is
            // enough to reach them, and is what the game would do itself.
            LoadPhoton();
            for (int i = 0; i < 20; i++) {
                Type found = Find();
                if (found != null) return found;
                Thread.Sleep(250);
            }
            return null;
        }

        static void LoadPhoton() {
            foreach (string managed in ManagedFolders()) {
                string[] names;
                try { names = Directory.GetFiles(managed, "*.dll"); } catch { continue; }
                foreach (string name in names) {
                    string file = Path.GetFileNameWithoutExtension(name).ToLowerInvariant();
                    if (!file.StartsWith("photon")) continue;
                    try { Assembly.LoadFrom(name); } catch { }
                }
            }
        }

        /// The game's `_Data/Managed` folders, where its own Photon assemblies sit.
        static List<string> ManagedFolders() {
            var found = new List<string>();
            try {
                foreach (string data in Directory.GetDirectories(_folder, "*_Data")) {
                    string managed = Path.Combine(data, "Managed");
                    if (Directory.Exists(managed)) found.Add(managed);
                }
            } catch { }
            return found;
        }

        /// Photon's client, whatever the game calls it: PUN2 puts it in
        /// `Photon.Pun.PhotonNetwork`, an older PUN in the global `PhotonNetwork`, and a
        /// game that bundles Photon into its own code keeps it there. Only the type name
        /// is depended on, so every version matches and none has to be listed.
        static readonly string[] Names = {
            "Photon.Pun.PhotonNetwork", "Photon.Realtime.PhotonNetwork", "PhotonNetwork",
        };

        static Type Find() {
            Assembly[] loaded = AppDomain.CurrentDomain.GetAssemblies();
            foreach (string name in Names) {
                foreach (Assembly assembly in loaded) {
                    Type type = Quiet(assembly, name);
                    if (type != null) return type;
                }
            }
            // A renamed namespace, or a build that nests it somewhere unexpected: any
            // type called PhotonNetwork whose class offers the client will do.
            foreach (Assembly assembly in loaded) {
                Type[] types;
                try { types = assembly.GetTypes(); } catch { continue; }
                foreach (Type type in types) {
                    if (type.Name == "PhotonNetwork" && type.GetProperty("IsConnected") != null) {
                        return type;
                    }
                }
            }
            return null;
        }

        static Type Quiet(Assembly assembly, string name) {
            try { return assembly.GetType(name, false); } catch { return null; }
        }

        static bool IsOn(Type photon) {
            object value = Get(photon, "IsConnected", null);
            return value is bool && (bool)value;
        }

        /// Watches the client state until it either authenticates or gives up, and
        /// turns the end of it into the one line the installer needs. Photon's states
        /// are read by name, so a version without one of them simply never matches.
        static string Follow(Type photon, int seconds) {
            DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);
            string seen = "";
            while (DateTime.UtcNow < deadline) {
                string state = Text(photon, "NetworkClientState", null, null);
                if (state != seen) {
                    seen = state;
                    Say("state " + state);
                    if (state.Contains("ConnectedToMaster") || state.Contains("Joined")
                        || state.Contains("ConnectedToGameserver") || state == "Connected") {
                        return "ok " + state;
                    }
                }
                if (state.Contains("Disconnected") || state.Contains("Error")) {
                    string cause = Text(photon, "DisconnectedCause", "NetworkingClient", null);
                    string detail = Text(photon, "DisconnectedCauseMessage", "NetworkingClient", null);
                    string server = Text(photon, "CloudRegion", "NetworkingClient", null);
                    return "fail " + cause
                        + (detail.Length > 0 ? " " + detail : "")
                        + (server.Length > 0 ? " region=" + server : "");
                }
                Thread.Sleep(400);
            }
            return "fail timeout at " + seen;
        }

        // MARK: - reflection

        static object Get(Type type, string name, object instance) {
            try {
                PropertyInfo property = type.GetProperty(name,
                    BindingFlags.Public | BindingFlags.Static | BindingFlags.Instance);
                if (property != null) {
                    return property.GetValue(instance, null);
                }
                FieldInfo field = type.GetField(name,
                    BindingFlags.Public | BindingFlags.Static | BindingFlags.Instance);
                if (field != null) return field.GetValue(instance);
            } catch {}
            return null;
        }

        /// A static property, or a property of a static property of the type — the
        /// shape `NetworkingClient.DisconnectedCause` has. `outer` names the holder.
        static string Text(Type type, string name, string outer, string unused2) {
            try {
                object holder = outer == null ? null : Get(type, outer, null);
                Object value = holder == null ? Get(type, name, null) : Get(holder.GetType(), name, holder);
                if (value == null) return "";
                string text = value.ToString();
                // An enum prints its name; an object prints its type.
                return text;
            } catch { return ""; }
        }

        static void Set(Type type, string name, object value) {
            try {
                PropertyInfo property = type.GetProperty(name, BindingFlags.Public | BindingFlags.Static);
                if (property != null && property.CanWrite) { property.SetValue(null, value, null); return; }
                FieldInfo field = type.GetField(name, BindingFlags.Public | BindingFlags.Static);
                if (field != null) field.SetValue(null, value);
            } catch {}
        }

        static void Invoke(Type type, string name, object[] args) {
            MethodInfo method = type.GetMethod(name, BindingFlags.Public | BindingFlags.Static,
                null, new Type[0], null);
            if (method == null) throw new MissingMethodException(name);
            method.Invoke(null, args);
        }

        static bool EarlyInEngine() {
            double up = EngineSeconds();
            return up >= 0 && up < 45;
        }

        static void Say(string line) {
            try {
                File.AppendAllText(_log, DateTime.UtcNow.ToString("HH:mm:ss") + " " + line + "\n");
            } catch {}
        }
    }
}
