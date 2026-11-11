using System;
using System.Collections.Generic;
using System.Globalization;
using AppKit;
using SideDesk.Models;
using SideDesk.UI.Yaml;

namespace SpikeNspanel.SideUi;

/// <summary>
/// 把 sideui 卡片声明渲染成 AppKit 的 <see cref="NSView"/>（对应 Windows 的 <c>UiRenderer</c>，
/// 但后端换成 AppKit）。<b>前半段（取值系统）逐条搬自 Windows</b>：<c>Ctx</c>/<c>Resolve</c>/
/// <c>ApplyValueSlot</c>/<c>Prop</c>/<c>StructuralProp</c>/<c>Num</c> 与框架无关，语义保持一致。
///
/// <para><b>三条不变式（沿自 Windows）</b>：① 取色/字号一律经 token 表（<see cref="UiTokensMac"/>），
/// 代码里不出现语义名/颜色/字号字面量；② 未实现的节点类型<b>报错，不静默跳过</b>；
/// ③ 取不到绑定路径时渲染成空 + 记日志并点名（不抛，也绝不静默）。</para>
///
/// <para><b>当前实现的节点</b>：<c>StickyBoard</c>（里程碑 1 的 sticky-notes 卡只用它）。
/// 其余类型走 fail-closed 分支抛出 —— 与 Windows 对未实现类型的处理同款，后续按需增补。</para>
/// </summary>
internal static class UiRendererMac
{
    private const string LogCategory = "ui.yaml";

    /// <summary>
    /// 渲染一份声明。<paramref name="data"/> 可为 null（纯静态卡片）；<paramref name="actions"/> 同理。
    /// 返回根 <see cref="NSView"/>；数据变化时在主线程重跑全部绑定求值。
    /// </summary>
    public static NSView Build(UiDocument doc, UiRegistries reg,
                               IUiDataSource? data, IUiActionHost? actions)
    {
        var ctx = new Ctx(reg, data, actions);
        var element = RenderNode(doc.Root, ctx, doc.Source, "body")
            ?? throw new InvalidOperationException($"{doc.Source}: 根节点渲染失败（单元素卡片不能没有内容）");

        if (data != null && ctx.Rebinders.Count > 0)
        {
            // 事件可能在后台线程触发 —— 切回主线程再赋值（AppKit 的线程亲和性）。
            data.Changed += () => NSApplication.SharedApplication.InvokeOnMainThread(() => Rerun(ctx));
        }
        return element;
    }

    private static void Rerun(Ctx ctx)
    {
        // 按下标而不是 foreach：某些重求值会改动这个列表（集合重建），foreach 会抛。
        for (var i = 0; i < ctx.Rebinders.Count; i++)
        {
            try { ctx.Rebinders[i](); }
            catch (Exception ex) { Log($"绑定求值失败：{ex.Message}"); }
        }
    }

    // ---------- 节点分派 ----------

    private static NSView? RenderNode(UiNode node, Ctx ctx, string source, string path)
    {
        // if：布尔路径，构建时求值一次（条件切换意味着集合增删，那类变化走宿主全量重建）。
        if (node.If is { Length: > 0 } ifPath)
        {
            if (!ctx.Resolve(ifPath, out var cond) || !string.Equals(cond?.ToString(), "true", StringComparison.Ordinal))
                return null;
        }

        var here = $"{path}({node.Type})";
        return node.Type switch
        {
            "StickyBoard" => RenderStickyBoard(node, ctx, here),
            _ => throw new InvalidOperationException(
                $"{source}: {here} 的节点类型 '{node.Type}' 在 AppKit 后端尚未实现。" +
                "（里程碑 1 只实现 StickyBoard；新增节点 = 同时改这里与 nodes.v1.json）")
        };
    }

    /// <summary>
    /// StickyBoard 宿主节点：<c>notes</c> 是类型直通（<see cref="StickyNote"/> 原对象列表），
    /// <c>editMode</c> 是布尔串。每行的点击/删除按位置经 <see cref="IUiActionHost"/> 挂
    /// （动作名 <c>sticky.open</c> / <c>sticky.delete</c>，value = 行下标）—— 与 Windows「宿主按位置 Wire」同契约。
    /// </summary>
    private static NSView RenderStickyBoard(UiNode node, Ctx ctx, string here)
    {
        var notesVal = ResolveSlot(node, "notes", ctx, here);
        var notes = notesVal as IReadOnlyList<StickyNote> ?? new List<StickyNote>();
        if (notesVal != null && notes.Count == 0 && notesVal is not IReadOnlyList<StickyNote>)
            Log($"{here}.notes 绑定值不是 List<StickyNote>（类型直通失败），按空列表处理");

        var editMode = string.Equals(ResolveSlot(node, "editMode", ctx, here)?.ToString(), "true", StringComparison.Ordinal);

        return StickyBoardNodeMac.Create(ctx.Reg, notes, editMode,
            onClick: i => Invoke(ctx, "sticky.open", i, here),
            onDelete: i => Invoke(ctx, "sticky.delete", i, here));
    }

    private static void Invoke(Ctx ctx, string action, int index, string here)
    {
        if (ctx.Actions == null || !ctx.Actions.TryInvoke(action, index.ToString(CultureInfo.InvariantCulture)))
            Log($"{here} 的动作 '{action}'(#{index}) 未注册（宿主未提供或名字拼错）");
    }

    // ---------- 取值：绑定 / i18n / 字面量 ----------

    /// <summary>解析一个值槽位为<b>原始对象</b>（类型直通用，如 StickyBoard.notes）。
    /// <c>{path}</c> 走数据源、<c>@key</c> 走 i18n、否则字面量字符串。取不到点名并返回 null。</summary>
    private static object? ResolveSlot(UiNode node, string prop, Ctx ctx, string here)
    {
        var raw = Prop(node, prop);
        if (raw.Length >= 2 && raw[0] == '{' && raw[^1] == '}')
        {
            var path = raw[1..^1];
            if (ctx.Resolve(path, out var v)) return v;
            Log($"{here}.{prop} 绑定路径 '{raw}' 取不到（数据源未提供）");
            return null;
        }
        if (raw.Length >= 1 && raw[0] == '@') return Lang(raw[1..]);
        return raw;
    }

    private static string Prop(UiNode node, string name) =>
        node.Props.TryGetValue(name, out var v) ? v : "";

    private static string StructuralProp(UiNode node, string prop, string here)
    {
        var v = Prop(node, prop);
        if (v.Length >= 2 && v[0] == '{' && v[^1] == '}')
        {
            Log($"{here}.{prop} 是结构性属性（决定容器怎么建），不支持绑定 '{v}' —— 已按默认值处理");
            return "";
        }
        return v;
    }

    private static double Num(string s, double fallback) =>
        double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : fallback;

    // i18n 桩：真正的 Framework.Lang.T 属后续抽取（与 StickyNote.cs 的 EmptyLabel 桩同处理）。
    private static string Lang(string key) => key;

    private static void Log(string message) => Console.WriteLine($"[{LogCategory}] {message}");

    // ---------- 渲染上下文（逐条搬自 Windows UiValueSlots.Ctx）----------

    private sealed class Ctx
    {
        private readonly List<Action> _rebinders;
        private readonly List<(string Name, IUiDataSource Source)> _scopes;

        public Ctx(UiRegistries reg, IUiDataSource? data, IUiActionHost? actions,
                   List<Action>? rebinders = null,
                   List<(string Name, IUiDataSource Source)>? scopes = null)
        {
            Reg = reg; Data = data; Actions = actions;
            _rebinders = rebinders ?? new List<Action>();
            _scopes = scopes ?? new List<(string, IUiDataSource)>();
        }

        public UiRegistries Reg { get; }
        public IUiDataSource? Data { get; }
        public IUiActionHost? Actions { get; }
        public List<Action> Rebinders => _rebinders;

        public Ctx WithScope(string name, IUiDataSource source)
        {
            var scopes = new List<(string, IUiDataSource)>(_scopes) { (name, source) };
            return new Ctx(Reg, Data, Actions, _rebinders, scopes);
        }

        /// <summary>解析绑定路径：<c>as.field</c> 从内层作用域找 <c>as</c>（内层遮蔽外层）；否则问卡片级数据源。</summary>
        public bool Resolve(string path, out object? value)
        {
            for (var i = _scopes.Count - 1; i >= 0; i--)
            {
                var (name, src) = _scopes[i];
                if (path.Length > name.Length + 1
                    && path.StartsWith(name, StringComparison.Ordinal)
                    && path[name.Length] == '.')
                    return src.TryGet(path[(name.Length + 1)..], out value);
            }
            if (Data != null) return Data.TryGet(path, out value);
            value = null;
            return false;
        }
    }
}
