pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils
import qs.modules.nexus

// Windows adaptation of modules/nexus/common/NetworkList.qml.
//
// Upstream calls Nmcli.connectingSsid() as a function and connects through
// NetworkConnection.handleConnect(), whose Linux path writes a NetworkManager
// keyfile. The staged Windows Nmcli exposes `connectingSsid` as a property and
// its connect request refuses any secured network without a saved Windows
// profile, because this shell never collects Wi-Fi credentials. The list,
// ordering, icons and motion stay upstream; the click path sends a gated
// facade request and defers a credential-protected network to Windows Settings.
ItemList {
    id: root

    required property NexusState nState
    property int limit: 0 // 0 = show all
    property bool enableFilter

    signal networkSelected(ap: var)

    function networkFilter(ap): bool {
        return true;
    }

    function needsWindowsSettings(ap): bool {
        return ap && ap.isSecure && !ap.hasProfile && !ap.active;
    }

    showList: Nmcli.wifiEnabled
    placeholderIcon: Nmcli.wifiEnabled ? "wifi_find" : "signal_wifi_off"
    placeholderText: {
        if (!Nmcli.wifiEnabled)
            return Tr.tr("Wi-Fi disabled");
        if (Nmcli.status === "location-denied")
            return Tr.tr("Allow location access to list networks");
        return Tr.tr("No networks found");
    }
    extraHeight: Nmcli.scanning ? Tokens.rounding.extraSmall : 0 // Inline so it isn't affected by anim
    list.anchors.top: scanningIndicator.bottom

    model: ScriptModel {
        values: {
            const connecting = Nmcli.connectingSsid;
            // Lower rank sorts higher in the list
            const rank = n => n.active ? 0 : n.ssid === connecting ? 1 : n.hasProfile ? 2 : 3;
            const sorted = [...Nmcli.networks].sort((a, b) => rank(a) - rank(b) || b.strength - a.strength);
            if (root.limit > 0 && sorted.length > root.limit)
                sorted.length = root.limit;
            return root.enableFilter ? sorted.filter(root.networkFilter) : sorted;
        }
    }

    delegate: StateLayer {
        id: network

        required property int index
        required property var modelData
        // The pending state belongs to the service: it is set when the adapter
        // accepts the request and cleared when the native result arrives, so a
        // refusal or failure re-enables the row without a local flag that only
        // a success path could clear.
        readonly property bool pending: Nmcli.pendingSelectionId !== ""
            ? Nmcli.pendingSelectionId === modelData.selectionId
            : Nmcli.connectingSsid === modelData.ssid || Nmcli.pendingSsid === modelData.ssid
        readonly property bool actionAvailable: modelData.active || root.needsWindowsSettings(modelData) || Nmcli.controlsEnabled
        property real textOpacity: disabled ? 0.5 : 1

        disabled: pending || !actionAvailable

        anchors.left: root.list.contentItem.left
        anchors.right: root.list.contentItem.right
        implicitHeight: networkLayout.implicitHeight + networkLayout.anchors.margins * 2
        radius: Tokens.rounding.extraSmall
        bottomLeftRadius: root?.last && index === root.list.count - 1 ? Tokens.rounding.extraLarge : radius
        bottomRightRadius: root?.last && index === root.list.count - 1 ? Tokens.rounding.extraLarge : radius
        anchors.fill: undefined

        onClicked: {
            if (modelData.active) {
                // Active network: open its detail/settings sub-page.
                root.nState.selectedNetworkSsid = modelData.ssid;
                root.nState.selectedNetworkId = modelData.selectionId || "";
                root.nState.networkDetailsFromSaved = false;
                root.nState.openSubPage(3);
            } else if (root.needsWindowsSettings(modelData)) {
                // No saved Windows profile: this shell must not collect the
                // key, so the credential prompt belongs to Windows.
                Qt.openUrlExternally("ms-settings:network-wifi");
            } else {
                Nmcli.connectToAccessPoint(modelData);
                root.networkSelected(modelData);
            }
        }

        Behavior on textOpacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        RowLayout {
            id: networkLayout

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            anchors.leftMargin: Tokens.padding.extraLarge
            anchors.rightMargin: Tokens.padding.extraLarge
            spacing: Tokens.spacing.medium

            MaterialIcon {
                text: Icons.getNetworkIcon(network.modelData.strength)
                color: network.modelData.active ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.medium
                opacity: network.textOpacity
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                opacity: network.textOpacity

                StyledText {
                    Layout.fillWidth: true
                    text: network.modelData.ssid
                    font: Tokens.font.body.small
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        const net = network.modelData;
                        const security = net.isSecure ? net.security : Tr.trCtx("Open", "open wifi network");
                        let status = "";
                        if (net.active)
                            status = Tr.trCtx("Connected", "network connected");
                        else if (net.hasProfile)
                            status = Tr.trCtx("Saved", "network saved");
                        if (status)
                            // TRANSLATORS: %1 = security type, %2 = connection status
                            return Tr.trCtx("Security: %1 • %2", "network security and status").arg(security).arg(status);
                        return Tr.trCtx("Security: %1", "network security").arg(security);
                    }
                    color: Colours.palette.m3outline
                    font: Tokens.font.label.small
                    elide: Text.ElideRight
                }
            }

            AnimLoader {
                sourceComp: network.pending ? loadingComp : iconComp

                Component {
                    id: iconComp

                    MaterialIcon {
                        text: network.modelData.active ? "settings" : root.needsWindowsSettings(network.modelData) ? "open_in_new" : "lock"
                        color: network.modelData.active ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.medium
                        opacity: network.textOpacity
                    }
                }

                Component {
                    id: loadingComp

                    LoadingIndicator {
                        implicitSize: Math.round(Tokens.font.icon.medium.pointSize * 1.3)
                    }
                }
            }
        }
    }

    StyledProgressBar {
        id: scanningIndicator

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 1
        implicitHeight: Nmcli.scanning ? Tokens.rounding.extraSmall : 0
        indeterminate: true

        Behavior on implicitHeight {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }
}
