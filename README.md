**RollControl** is a Windower addon that automates rolls when on Corsair and displays accurate Phantom Roll effects while on any job.

## Features

**Automatic Rolls:**
	- Rolls while Engaged or Idle
	- Automatically pauses rolling while Paralysis, Impairment, or Amnesia are active and resumes once the debuff clears
	- Clear busts and blocks Fold unless you have a bust or you’ve attempted Fold more than once
	- Suspends rolls while **Sneak/Invisible** are active

**Display Overlay:**
	- Shows **Roll 1** and **Roll 2**
	- Shows rolls on/off
	- Shows when rolls are suspended by Sneak/Invisible
	- Indicates if **Engaged Mode** is enabled
	
**Double-Up:**
	- Uses **Snake Eye** on rolls 7 - 10
	- Double-Ups low rolls
	- Blocks accidental Double-Up on a Lucky roll and requires a second Double-Up command to confirm

**Hold TP:**
    - Prevents rolls from being used while your TP is at least 1000 (optional)
    - Resumes rolls once your TP drops below 1000
	- Best used if Tactician's Roll is active

**Roll Tracker:**
	- Uses **Crooked Cards** with Roll 1 (optional)
	- Displays correct values for **Crooked Cards** bonus (COR only), gear and job bonuses in roll effect (any job)
	- You must find out the roll+ potency from the COR in party and configure it

## Commands

Do not type | or [ ] when using commands:

List commands: //rc help

- //rc on|off - Enable/Disable
- //rc roll1 [name] - Set Roll #1
- //rc roll2 [name] - Set Roll #2
- //rc cc on|off - Crooked Cards on/off
- //rc holdtp on|off - Hold TP on/off
- //rc rollplus 0|3|5|6|7|8 - Set the COR roll+ potency (not self)
- //rc display on|off - Display on/off
- //rc engaged on|off - Rolls only when engaged
- //rc status - Show current status
