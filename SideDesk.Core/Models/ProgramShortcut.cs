using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;

namespace SideDesk.Models
{
    public class ProgramShortcut
    {
        public string Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string Command { get; set; } = string.Empty;
        public string Arguments { get; set; } = string.Empty;
        public string BackgroundColor { get; set; }
        public DateTime CreatedAt { get; set; }

        public ProgramShortcut()
        {
            Id = Guid.NewGuid().ToString("N");
            CreatedAt = DateTime.Now;
            BackgroundColor = "#9B59B6";
        }
    }

    public static class ProgramShortcutManager
    {
        private static readonly string _filePath;
        // 由静态构造函数中的 Load() 填充；此处给空列表兜底
        private static List<ProgramShortcut> _shortcuts = new List<ProgramShortcut>();
        private static readonly object _lock = new object();

        static ProgramShortcutManager()
        {
            string folder = Framework.AppPaths.DataDir;
            if (!Directory.Exists(folder))
            {
                Directory.CreateDirectory(folder);
            }
            _filePath = Path.Combine(folder, "programs.json");
            Load();
        }

        public static List<ProgramShortcut> GetAll()
        {
            lock (_lock)
            {
                return new List<ProgramShortcut>(_shortcuts);
            }
        }

        public static void Add(ProgramShortcut shortcut)
        {
            lock (_lock)
            {
                _shortcuts.Add(shortcut);
                Save();
            }
        }

        public static void Remove(string id)
        {
            lock (_lock)
            {
                _shortcuts.RemoveAll(s => s.Id == id);
                Save();
            }
        }

        private static void Load()
        {
            try
            {
                if (File.Exists(_filePath))
                {
                    string json = File.ReadAllText(_filePath);
                    _shortcuts = JsonConvert.DeserializeObject<List<ProgramShortcut>>(json) ?? new List<ProgramShortcut>();
                }
                else
                {
                    _shortcuts = new List<ProgramShortcut>();
                }
            }
            catch
            {
                _shortcuts = new List<ProgramShortcut>();
            }
        }

        private static void Save()
        {
            try
            {
                string json = JsonConvert.SerializeObject(_shortcuts, Formatting.Indented);
                File.WriteAllText(_filePath, json);
            }
            catch
            {
                // Ignore save errors
            }
        }
    }
}
