// Panel button for auto-rotate (like Android's rotation tile): tap to lock or unlock the screen
// rotation. State lives in ~/.config/nx789j/no-autorotate (nx-autorotate), which nx-orientation
// reads; it is polled here too, so a change made elsewhere shows up.
// Built like Plasma's own Show Desktop button: the button IS the full representation (a separate
// compactRepresentation was never created in this panel).
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property bool locked: false

    preferredRepresentation: fullRepresentation
    Plasmoid.icon: locked ? "rotation-locked-portrait-symbolic" : "rotation-allowed-symbolic"
    Plasmoid.title: i18n("Auto-rotate")
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    Plasmoid.onActivated: toggle()
    toolTipMainText: locked ? i18n("Auto-rotate is off") : i18n("Auto-rotate is on")
    toolTipSubText: locked ? i18n("The screen stays as it is. Tap to turn auto-rotate on.")
                           : i18n("The screen turns with the phone. Tap to lock it.")

    Layout.minimumWidth: Kirigami.Units.iconSizes.medium
    Layout.minimumHeight: Kirigami.Units.iconSizes.medium
    Layout.maximumWidth: Layout.minimumWidth
    Layout.maximumHeight: Layout.minimumHeight
    Layout.preferredWidth: Layout.minimumWidth
    Layout.preferredHeight: Layout.minimumHeight

    function toggle() {
        locked = !locked;
        run(locked ? "off" : "on");
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

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        activeFocusOnTab: true
        onClicked: Plasmoid.activated()
        Accessible.name: Plasmoid.title
        Accessible.description: root.toolTipMainText
        Accessible.role: Accessible.Button
        Accessible.onPressAction: Plasmoid.activated()

        Kirigami.Icon {
            anchors.fill: parent
            active: mouseArea.containsMouse
            source: Plasmoid.icon
        }
    }
}
