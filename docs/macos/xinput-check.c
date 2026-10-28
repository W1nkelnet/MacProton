/*
 * Game controller check for Wine on macOS.
 *
 * Polls XInput (what most games use for Xbox-style controllers) for the
 * given number of seconds and prints connected controllers and every
 * change of buttons, triggers and sticks.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 xinput-check.c -o xinput-check.exe -lxinput
 * usage: xinput-check.exe [seconds]
 */
#include <windows.h>
#include <xinput.h>
#include <stdio.h>
#include <stdlib.h>

static const struct { WORD mask; const char *name; } buttons[] =
{
    { XINPUT_GAMEPAD_A, "A" }, { XINPUT_GAMEPAD_B, "B" }, { XINPUT_GAMEPAD_X, "X" }, { XINPUT_GAMEPAD_Y, "Y" },
    { XINPUT_GAMEPAD_LEFT_SHOULDER, "LB" }, { XINPUT_GAMEPAD_RIGHT_SHOULDER, "RB" },
    { XINPUT_GAMEPAD_BACK, "View" }, { XINPUT_GAMEPAD_START, "Menu" },
    { XINPUT_GAMEPAD_LEFT_THUMB, "LS" }, { XINPUT_GAMEPAD_RIGHT_THUMB, "RS" },
    { XINPUT_GAMEPAD_DPAD_UP, "Up" }, { XINPUT_GAMEPAD_DPAD_DOWN, "Down" },
    { XINPUT_GAMEPAD_DPAD_LEFT, "Left" }, { XINPUT_GAMEPAD_DPAD_RIGHT, "Right" },
};

static int stick(SHORT value) { return value > 16000 ? 1 : value < -16000 ? -1 : 0; }

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 20, i, user, found = 0;
    XINPUT_STATE last[XUSER_MAX_COUNT] = {{0}};
    BOOL connected[XUSER_MAX_COUNT] = {0};
    DWORD end = GetTickCount() + seconds * 1000;

    printf("Polling XInput for %d seconds, press buttons and move the sticks...\n", seconds);
    fflush(stdout);
    while (GetTickCount() < end)
    {
        for (user = 0; user < XUSER_MAX_COUNT; user++)
        {
            XINPUT_STATE state;
            const XINPUT_GAMEPAD *g = &state.Gamepad, *o = &last[user].Gamepad;
            BOOL now = XInputGetState(user, &state) == ERROR_SUCCESS;

            if (now != connected[user])
            {
                printf("Controller %d %s\n", user, now ? "connected" : "disconnected");
                connected[user] = now;
                if (now) found = 1;
            }
            if (!now || state.dwPacketNumber == last[user].dwPacketNumber) continue;

            for (i = 0; i < ARRAYSIZE(buttons); i++)
                if ((g->wButtons ^ o->wButtons) & buttons[i].mask)
                    printf("  %d: %s %s\n", user, buttons[i].name, g->wButtons & buttons[i].mask ? "pressed" : "released");
            if ((g->bLeftTrigger > 128) != (o->bLeftTrigger > 128))
                printf("  %d: LT %s\n", user, g->bLeftTrigger > 128 ? "pressed" : "released");
            if ((g->bRightTrigger > 128) != (o->bRightTrigger > 128))
                printf("  %d: RT %s\n", user, g->bRightTrigger > 128 ? "pressed" : "released");
            if (stick(g->sThumbLX) != stick(o->sThumbLX) || stick(g->sThumbLY) != stick(o->sThumbLY))
                printf("  %d: left stick %d,%d\n", user, stick(g->sThumbLX), stick(g->sThumbLY));
            if (stick(g->sThumbRX) != stick(o->sThumbRX) || stick(g->sThumbRY) != stick(o->sThumbRY))
                printf("  %d: right stick %d,%d\n", user, stick(g->sThumbRX), stick(g->sThumbRY));
            last[user] = state;
            fflush(stdout);
        }
        Sleep(10);
    }
    printf("%s\n", found ? "OK: controller seen" : "FAIL: no controller seen");
    return !found;
}
