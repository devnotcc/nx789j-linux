// NX789J system tray: auto-rotate, clipboard, volume and brightness go into the tray's
// "Status and Notifications" popup (the arrow next to the clock) instead of the narrow panel.
// Applied by nx-orientation after every panel layout (the layouts make new trays) and at login.
// Safe to re-run. Pattern from KDE's scripting examples (SystrayContainmentId -> desktopById).
var hide = ["org.nx789j.autorotate", "org.kde.plasma.clipboard", "org.kde.plasma.volume",
            "org.kde.plasma.brightness"];
var all = panels();
var done = 0;
for (var p = 0; p < all.length; p++) {
    var widgets = all[p].widgets();
    for (var w = 0; w < widgets.length; w++) {
        if (widgets[w].type !== "org.kde.plasma.systemtray") continue;
        var id = widgets[w].readConfig("SystrayContainmentId");
        if (!id) continue;
        var tray = desktopById(id);
        if (!tray) continue;
        tray.currentConfigGroup = ["General"];
        var list = function (key) {
            var v = tray.readConfig(key);
            if (!v) return [];
            return (typeof v === "string" ? v.split(",") : v).filter(function (x) { return x !== ""; });
        };
        var extra = list("extraItems"), known = list("knownItems"), hidden = list("hiddenItems");
        var shown = list("shownItems").filter(function (x) { return hide.indexOf(x) < 0; });
        for (var i = 0; i < hide.length; i++) {
            if (extra.indexOf(hide[i]) < 0) extra.push(hide[i]);
            if (known.indexOf(hide[i]) < 0) known.push(hide[i]);
            if (hidden.indexOf(hide[i]) < 0) hidden.push(hide[i]);
        }
        tray.writeConfig("extraItems", extra);
        tray.writeConfig("knownItems", known);
        tray.writeConfig("hiddenItems", hidden);
        tray.writeConfig("shownItems", shown);
        tray.reloadConfig();
        done++;
    }
}
print("trays: " + done);
