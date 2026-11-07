// Auto-rotate (like Android's rotation tile), as a system tray item: it sits in the tray's
// "Status and Notifications" popup (hiddenItems, set by plasma-tray.js) and opens a page with an
// on/off switch. State lives in ~/.config/nx789j/no-autorotate (nx-autorotate), which
// nx-orientation reads; it is polled here too, so a change made elsewhere shows up.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    property bool locked: false

    Plasmoid.icon: locked ? "rotation-locked-portrait-symbolic" : "rotation-allowed-symbolic"
    Plasmoid.title: i18n("Auto-rotate")
    toolTipMainText: locked ? i18n("Auto-rotate is off") : i18n("Auto-rotate is on")
    toolTipSubText: locked ? i18n("The screen stays as it is.") : i18n("The screen turns with the phone.")

    function setLocked(l) {
        locked = l;
        run(l ? "off" : "on");
    }

    // (a source only runs again once disconnected)
    function run(args) { shell.connectSource("nx-autorotate " + args); }

    P5Support.DataSource {
        id: shell
        engine: "executable"
        onNewData: (source, data) => {
            const out = (data["stdout"] || "").trim();
            if (out === "on" || out === "off") root.locked = out === "off";
            disconnectSource(source);
        }
    }

    Timer {
        interval: 4000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.run("status")
    }

    // no own compactRepresentation: the default one (Plasmoid.icon) gets the tray's tap/click
    // handling; an extra MouseArea made a tap open and close the popup at once

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 6
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Kirigami.Icon {
                source: Plasmoid.icon
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }
            Kirigami.Heading {
                text: i18n("Auto-rotate")
                level: 3
                Layout.fillWidth: true
            }
            PlasmaComponents3.Switch {
                checked: !root.locked
                onToggled: root.setLocked(!checked)
                Accessible.name: i18n("Auto-rotate")
            }
        }

        PlasmaComponents3.Label {
            text: root.locked ? i18n("The screen stays as it is. Turn the switch on to let it turn with the phone.")
                              : i18n("The screen turns with the phone. Turn the switch off to keep it as it is.")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Item { Layout.fillHeight: true }
    }
}
