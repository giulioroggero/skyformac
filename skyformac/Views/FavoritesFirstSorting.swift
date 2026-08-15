/// The "favorites first" stable sort every project/session list in the browser uses — a plain
/// stable sort, so everything else keeps whatever order it was already going to show in (name,
/// last activity, whatever the current view mode/sort otherwise applies). Shared here (generic,
/// via an explicit `isFavorite` key path since `Project`/`Session` don't share a protocol) rather
/// than reimplemented per call site — `ProjectsBrowserView`'s own project list, its Next/Previous
/// Project/Session sibling navigation, and `ProjectDetailPane`'s session cards all need the exact
/// same order, and a previous version of this app reimplemented the one-line sort three separate
/// times instead.
func favoritesFirst<T>(_ items: [T], isFavorite: (T) -> Bool) -> [T] {
    items.sorted { isFavorite($0) && !isFavorite($1) }
}
