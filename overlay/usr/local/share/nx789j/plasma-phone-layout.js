// NX789J panel layout for the portrait phone screen (1216x2688 at scale 2, ~608 points wide):
// a slim status bar on top (tray + clock) and a taller dock at the bottom (launcher + apps),
// instead of Plasma's single floating desktop panel, which is far too cramped at this width.
// Run once per user by nx-plasma-layout (Plasma's evaluateScript); safe to re-run.
var old = panels();
for (var i = 0; i < old.length; i++) old[i].remove();

var top = new Panel;
top.location = "top";
top.floating = false;
top.height = Math.round(gridUnit * 1.6);
top.addWidget("org.kde.plasma.panelspacer");
var tray = top.addWidget("org.kde.plasma.systemtray");
var clock = top.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", false);

var dock = new Panel;
dock.location = "bottom";
dock.floating = false;
dock.height = Math.round(gridUnit * 3);
dock.addWidget("org.kde.plasma.kickoff");
var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", "applications:org.kde.konsole.desktop,applications:org.kde.dolphin.desktop,applications:firefox-esr.desktop,applications:systemsettings.desktop");
tasks.writeConfig("iconSpacing", 2);
dock.addWidget("org.kde.plasma.showdesktop");
