@testable import AppBundle
import Common
import XCTest

@MainActor
final class ImportI3Test: XCTestCase {
    func testSmokeImport() {
        let i3Config = """
            set $mod Mod4
            set $term alacritty

            font pango:monospace 8
            floating_modifier $mod

            bindsym $mod+Return exec --no-startup-id $term
            bindsym $mod+Shift+q kill
            bindsym $mod+h focus left
            bindsym $mod+j focus down
            bindsym $mod+space floating toggle
            bindsym $mod+f fullscreen toggle
            bindsym $mod+1 workspace number 1
            bindsym $mod+Shift+1 move container to workspace number 1
            bindsym $mod+r mode "resize"

            mode "resize" {
                bindsym h resize shrink width 10 px or 5 ppt
                bindsym l resize grow width 10 px or 5 ppt
                bindsym Return mode "default"
                bindsym Escape mode "default"
            }

            bar {
                status_command i3status
                position top
            }

            for_window [class="SomeObscureLinuxApp"] floating enable
            for_window [class="firefox" title="Library"] floating enable
            assign [class="Slack"] 3
            workspace 1 output primary
            gaps inner 8
            gaps outer 4
            exec_always --no-startup-id autotiling
            focus_follows_mouse no
            """
        let result = importI3Config(i3Config)

        // The invariant: importer output must always parse cleanly
        let parsed = parseConfig(result.toml)
        assertEquals(parsed.errors.map { $0.description(.error) }, [])

        // Spot checks
        assertTrue(result.toml.contains("alt-enter = 'exec-and-forget alacritty'"))
        assertTrue(result.toml.contains("alt-shift-q = 'close'"))
        assertTrue(result.toml.contains("alt-h = 'focus left'"))
        assertTrue(result.toml.contains("alt-space = 'layout floating tiling'"))
        assertTrue(result.toml.contains("alt-1 = 'workspace 1'"))
        assertTrue(result.toml.contains("alt-shift-1 = 'move-node-to-workspace 1'"))
        assertTrue(result.toml.contains("alt-r = 'mode resize'"))
        assertTrue(result.toml.contains("[mode.resize.binding]"))
        assertTrue(result.toml.contains("h = 'resize width -5%'"))
        assertTrue(result.toml.contains("enter = 'mode main'"))
        assertTrue(result.toml.contains("if.app-name-regex-substring = 'SomeObscureLinuxApp'"))
        assertTrue(result.toml.contains("if.app-id = 'org.mozilla.firefox'"))
        assertTrue(result.toml.contains("if.window-title-regex-substring = 'Library'"))
        assertTrue(result.toml.contains("treat-as = 'float'"))
        assertTrue(result.toml.contains("run = 'move-node-to-workspace 3'"))
        assertTrue(result.toml.contains("1 = 'main'")) // workspace 1 output primary
        assertTrue(result.toml.contains("inner.vertical = 8"))
        assertTrue(result.toml.contains("outer.top = 4"))
        assertTrue(result.toml.contains("exec-and-forget autotiling"))
        assertTrue(result.toml.contains("focus-follows-mouse.enabled = false"))

        // bar block skipped with a reason, its contents not treated as directives
        assertTrue(result.diagnostics.contains { $0.original.hasPrefix("bar") && $0.severity == .skipped })
        assertTrue(!result.toml.contains("status_command"))
        // font + floating_modifier skipped
        assertTrue(result.diagnostics.contains { $0.original.hasPrefix("font") })
        assertTrue(result.diagnostics.contains { $0.original.hasPrefix("floating_modifier") })
    }

    func testMod4FallsBackToCmdWhenMod1AlsoUsed() {
        let config = """
            bindsym Mod4+a workspace 1
            bindsym Mod1+a workspace 2
            """
        let result = importI3Config(config)
        assertTrue(result.toml.contains("cmd-a = 'workspace 1'"))
        assertTrue(result.toml.contains("alt-a = 'workspace 2'"))
    }

    func testUnknownKeysymIsSkippedNotFatal() {
        let config = """
            bindsym XF86AudioRaiseVolume exec pactl set-sink-volume 0 +5%
            bindsym Mod4+t workspace T
            """
        let result = importI3Config(config)
        assertEquals(result.skippedCount, 1)
        assertTrue(result.toml.contains("alt-t = 'workspace T'"))
        let parsed = parseConfig(result.toml)
        assertEquals(parsed.errors.map { $0.description(.error) }, [])
    }
}
