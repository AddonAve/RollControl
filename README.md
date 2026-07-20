**RollControl** is a Windower addon that combines the functionality of the Roller and RollTracker addons.
It automates rolls when COR is main or sub job and displays accurate Phantom Roll effects while on any job.

## Release Notes

**Version 2.0.6**
	1. Fixed an issue in Version 2.0.4.
	2. Will now pause the current roll sequence instead of cancelling it while idle and moving.
	
**Version 2.0.4**
	1. Will not roll while idle and moving.

**Version 2.0.2**
	1. Modified text in display overlay.

**Version 2.0.0**
	1. Crooked Cards can now be set to use with Roll 1 or Roll 2.
	2. Crooked Cards status for Roll 1 or Roll 2 is now shown in the display overlay.
	3. Fixed the calculation for Bolter's Roll.

## Features

**Phantom Rolls:**
	- Automaticall rolls while Engaged or Idle
	- Automatically pauses rolls while Amnesia, Impairment, or Paralysis are active and resumes once the debuff clears
	- Clear busts and blocks Fold unless you have a bust or you’ve attempted Fold more than once
	- Crooked Cards can be set to use with Roll 1 or Roll 2
	- Suspends rolls while Sneak/Invisible are active

**Display Overlay:**
	- Shows **Roll 1** and **Roll 2**
	- Shows if rolls are on/off
	- Shows Crooked Cards status for Roll 1 or Roll 2
	- Shows Engaged status (rolls only when engaged)
	- Shows when rolls are suspended by Sneak/Invisible
	
**Double-Up + Snake Eye:**
	- Blocks accidental Double-Up on a Lucky roll and requires a second Double-Up command to confirm
	- Double-Up on low rolls
	- Retries Double-Up if you get unable to use job ability due to performing another action
	- Snake Eye is used on unlucky rolls and roll 10

**Hold TP:**
	- Best used if Tactician's Roll is set
    - Prevents rolls from being used while your TP is at least 1000 (optional)
    - Resumes rolls once your TP drops below 1000

**Roll Tracker:**
	- Displays correct roll effect values for **Crooked Cards** bonus for the (COR), gear and job bonuses for roll effect displays for (any job)
	- You must find out the roll+ potency from the COR in party and configure it in settings

## Commands

Do not type | or [ ] when using commands:

List commands: //rc help

- //rc [on|off] - Enable/Disable
- //rc roll1 <name> - Set Roll 1
- //rc roll2 <name> - Set Roll 2
- //rc cc [on|off] - Crooked Cards on/off
- //rc cc [roll1|roll2] - Set Crooked Cards for Roll 1 or Roll 2
- //rc holdtp on|off - Hold TP on/off
- //rc rollplus [0|3|5|6|7|8] - Set the COR roll+ potency (not self)
- //rc display [on|off] - Display on/off
- //rc engaged [on|off] - Rolls only when engaged
- //rc status - Show current status
