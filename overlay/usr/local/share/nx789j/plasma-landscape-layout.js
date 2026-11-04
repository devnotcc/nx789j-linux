// NX789J panel layout for landscape (2688x1216 at scale 2.5, ~1075 points wide): everything in
// one bottom panel - launcher, apps, tray, clock. The portrait layout is plasma-phone-layout.js;
// nx-orientation switches between them when the screen rotates. Safe to re-run.
var old = panels();
for (var i = 0; i < old.length; i++) old[i].remove();

var dock = new Panel;
dock.location = "bottom";
dock.floating = false;
dock.height = Math.round(gridUnit * 2.4);
dock.addWidget("org.kde.plasma.kickoff");
var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", "applications:org.kde.konsole.desktop,applications:org.kde.dolphin.desktop,applications:firefox-esr.desktop,applications:systemsettings.desktop");
tasks.writeConfig("iconSpacing", 2);
dock.addWidget("org.kde.plasma.panelspacer");
dock.addWidget("org.nx789j.autorotate");
dock.addWidget("org.kde.plasma.systemtray");
var clock = dock.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
dock.addWidget("org.kde.plasma.showdesktop");
