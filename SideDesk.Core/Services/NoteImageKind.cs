namespace SideDesk.Services;

/// <summary>
/// 笔记图片归属种类（提取自 Windows Services/NoteImageService.cs）。
/// 纯枚举，无平台依赖 —— 放 Core 供接缝 <see cref="INoteImageCodec"/> 与具体实现共用。
/// </summary>
public enum NoteImageKind
{
    /// <summary>便签（note-images / #216）</summary>
    StickyNote,
    /// <summary>记事（desk-note-images）</summary>
    DeskNote,
}
