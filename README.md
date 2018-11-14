# ZenTracker - Cooldown tracker
 
This is addon version of this aura: https://wago.io/r14U746B7

**All credit goes to Zen.** I just converted his weakaura to addon and added configuration GUI. 

No need to install LibGroupInspect, it is included in this addon.

**Dependencies:** [WeakAuras2](https://www.wowace.com/projects/weakauras-2)

## Description

Unlike some other interrupt tracking WAs, ZenTracker displays static bars instead of 
creating them only after a spell is cast for the first time. Additionally, ZenTracker 
can be used to track all types of useful spell types beyond interrupts (e.g., hard CC 
and utility CDs). Finally, ZenTracker uses a lightweight front-end client model, 
allowing easy customization of the front-end display WAs while the back-end Addon does 
all of the heavy lifting.

ZenTracker uses a hybrid tracking model: For other players using ZenTracker, it will 
use addon messages to exchange *accurate* cooldown information. For any players not 
using ZenTracker, it will fallback to local, combatlog-based tracking. While the 
combatlog-based tracking does contain support for many cooldown modifiers, it is not 
complete; in some cases (e.g., reduction via azerite trait) it will overestimate the cooldown.

### NOTE: You **MUST** have one or more front-end WAs to see anything!

## Back-End Addon Configuration

Unlike aura version, this addon has proper GUI configuration. 
You can find it in Interface -> Addons -> ZenTracker

## Default Front-End WAs

You can configure the front-end WAs to look however you like, but the ones below serve as 
reasonable defaults. You can find information on how to configure them in the 
"Front-End Configuration" section below (and the images included on their respective Wago pages).

|      Type      |         Sorting          |            Link             |     Update      |
|----------------|--------------------------|-----------------------------|-----------------|
|  Progress Bar  |  Info (Type>Spell>Name)  |  https://wago.io/r1YXub93X  |  Iteration 31+  |
|  Progress Bar  |  Availability            |  https://wago.io/BJnNd-c2X  |  Iteration 31+  |


## Community Front-End WAs

Here are some of the available front-end WAs that have been developed by other members of the 
community. Check them out for amazing functionality beyond the default front-end WAs provided above!


| Author   |            Link             |                             Description                             |
|----------|-----------------------------|---------------------------------------------------------------------|
|  Nnogga  |  https://wago.io/Hk8U8kanm  |  Displays rows of icons that are attached to party member UI frames |

## Front-End Configuration

You can find the configuration settings under "ZT Front-End ..." -> Actions Tab -> Expand OnInit Code. 
The comments explain what each setting controls.

You can change the look and feel of the front-end WAs as usual using the WeakAuras configuration menu under 
the Group/Display tabs. Each of the default front-end WAs above contains a list of types of spells it displays. 
The example below will display HARDCC, SOFTCC, DISPEL, and UTILITY types.

```lua
aura_env.types = {
    INTERRUPT = false,
    HARDCC    = true,
    SOFTCC    = true,
    DISPEL    = true,
    EXTERNAL  = false,
    HEALING   = false,
    UTILITY   = true,
    STHARDCC  = false,
    PERSONAL  = false,
    IMMUNITY  = false,
    DAMAGE    = false,
}
```

## Detailed Information

This is the backend portion which tracks cooldowns associated with various types of 
spells (e.g., HARDCC and INTERRUPT). It exposes the following event types to WeakAuras, 
which you can use in developing your own front-end WAs for ZenTracker, or any other WAs 
that depend on group spell cast information:

- `ZT_ADD (type, watchID, member, spellID)`
- `ZT_TRIGGER (type, watchID, duration, expiration)`
- `ZT_REMOVE (type, watchID)`

Arguments:

1. `type` is the type of spell. Currently each tracked spell is assigned one of the following types: 
HARDCC, SOFTCC, DISPEL, INTERRUPT, EXTERNAL, HEALING, and UTILITY, STHARDCC.
2. `watchID` is a unique identifier for the purposes of using a Trigger State Updater in WeakAura. 
This can be used to index into the allstates table.
3. `member` is a table consisting of information about the group member, with fields such as .name and .specID.
4. `spellID` corresponds to the WoW API ID for the spell. This can be used to display an appropriate icon.
5. `duration` is the original time (in seconds) of the cooldown, adjusted according to talents taken by 
the group member that cast it.
6. `expiration` is when the cooldown will expire. Initially equal to "GetTime() + duration", but may be 
modified in future ZT_TRIGGER events

The back-end WA also listens for ZT_REGISTER (type, id) and ZT_UNREGISTER (type, id) events from the 
front-end WAs, where type is the same as above and id is a unique identifier for the front-end WA 
(e.g., aura_env.id). This allows flexible loading of front-end WAs according to the WA configuration 
menu, and for the back-end to only watch types that one or more front-end WAs are interested in.


