Please feel free report new issues under issues section (full BugSack data would be ideal), or just talk to me in game.

IS ADDON CURRENTLY SAFE TO USE : YES

NOTE - YOU SHOULD ONLY USE THE RELEASE VERSION ON CURSEFORGE.  THE LUA LISTED HERE IS IN DEVELOPMENT

Required urgently:
* Prevent out of date editors from syncing at all
* Warnings on functions that change dkp table version to advise editor they aren't the highest version
* A bold change to improve sync efficiency (might brake everything so held off for now)

Features to deliver ASAP:
* Redo the way DKP table saves to a single button commit (hook into editor rollback funcitonality)
* Revisit audit log completely (might be better after the dkp save change)
* Use alt data for editors to remove their alts from sync (better data integrity)
* Add a small sync to check table version between non editors and colour the sync info if out of date
* Add RW countdown timer to ML tab


Outstanding bugs:
* Force sync isnt showing editor response from Luna
* Check that if force sync is declined or fails, sync information reflects this (maybe add "last sync status"?)
* Refinement needed to Sync status for editors to find the highest version recorded for dkp table
  

Ideas for future releases (significant work):
* Colour coding in the logs to make them easier to read
* Full support for DKP bidding
* Raid group planner
* Tactics
* are you back check?




-------------------------------------------------------

1.12.69 Changelog
-------------------------------------------------------
Added features:
* Sync info now shows highest known dkp table version


Bugs squashed:
*  Out of date addon users functions/calculates properly


1.11.69 Changelog
-------------------------------------------------------
Same as 1.10.69 (thanks curse)



1.10.69 Changelog
-------------------------------------------------------
Added features:
* Version control on Alt Tracker to try to improve sync lag



1.9.69 Changelog
-------------------------------------------------------
Added features:
* New Countdown button on ML tab


Bugs squashed:
*  DKP Table version wrong on force sync
*  Fixed sync addon users counter



1.8.69 Changelog
-------------------------------------------------------
Bugs squashed:
*  DKP Table version wrong on force sync



1.7.69 Changelog
-------------------------------------------------------
Bugs squashed:
*  Broken name referencing for editors on alts



1.6.69 Changelog
-------------------------------------------------------
Added features:
* Editor to Editor sync now makes a backup table that can be restored
* Editor sync now happens from the editor with the highest dkp table version rather than highest rank
* Improved whisper response functionality
* Table version in sync info

Bugs squashed:
* Fixed bad sync between editors
* Sync info now correctly shows editor syncs
* Editor sync now updates the dkp table version number properly
* Sweeping changes to addon_loaded, player_login and guild_roster_update to try and reduce lag spikes



1.5.69 Changelog
-------------------------------------------------------
Added features:
* Alt Tracker now shows online status

Bugs squashed:
* Moved the add options on Alt Tracker to under the boxes



1.4.69 Changelog
------------------------------------------------------------
Added features:
* New Alt Tracker tab!
* Add ALT columns to ML Scorecard
* Ml Scorecard formatting puts Mains at the top and Alts at the bottom (looks better)
* Ml Scorecard list now auto filters non guild members
* Inviter uses ALT data in info
* New (totally not stolen) SYNC display in the toolbar
* Add flag on DKP table to show alts
* Right click minimap now opens ML table
* Escape closes the addon again (it's the little things right)

Bugs Squashed:
* ML Scorecard loads names without needing reset
* Inviter shows "In your group 0" when not grouped (cosmetic)
* Hide in group should not remove checked names from summary on Inviter
* Window wont move with ML Scorecard open
* Escape does not close the addon (not really a bug - QOL)
* * ML notes needs 2 clicks



1.3.69 Changelog
-------------------------------------------------------------
Added features:
* (Done) Balance capped at 300
* (Done) Capped 300 now colours purple
* (Done) ML Scorecard reset/filter to add non dkp table users to ML list
* (Done) RL Tools detects when group/raid members aren't on the DKP table for buttons

Bugs Squashed:
* (Fixed) Balance calculations sorted on table and whispers
  


1.2.69 Changelog
-------------------------------------------------------------
Bugs Squashed:
* (Done) ML Scorecard group/raid filter was broken



1.1.69 Changelog
-------------------------------------------------------------

Added features:
* (Done) Master switch to turn SYNC off on Editors page
* (Done) Option for the Editors tab that shows how many known addon users. Also fixed that the addon wasn't storing data for addon users properly.
* (Done) Option on the RL tools tab that selects raid members
* (Done) Edit button for DKP tab editors
* (Done) Mangs changes - (tweaks to names of dkp table columns and "new week" button)
* (Done) Redo RL Tools functionality to make it as lightweight as possible
* (Done) Toggle for Inviter to also show online guildies who aren't on dkp table
* (Done but caused sorting bug to reappear) Filter for DKP tab to show/hide inactive users
* (Done but caused sorting bug to reappear) Filter for DKP tab to show current raid members
* (Done) Toggle for Inviter to also show online guildies who aren't on dkp table
* (Done) Enhance Inviter information and list to clearly show who's offline or in group
* (Done) Inactive user option for dkp table (biggie)


Bugs Squashed:

* (Fixed) DKP table headers cutoff?  (Rotation)
* (Fixed) When not in group you are not missing in inviter, and ML scorecard shows blank
* Editors moving to alts will allow their DKP table to be overridden by other editors because they now fall into the autosync rule.  Workaround is they do not use addon on alts.

Showstopper Bugs Squashed:
* (Fixed) The "Show hidden records" and "Show current raid members" options on DKP tab has the old bug where it hides table rows at the end of the list.  Ultimately the DKP table has a redraw logic issue that prevents the table refreshing correctly, likely due to duplication of process or incorrect recycling of assets.  Thankfully it doesn't impact the data at all it's just a view issue that seems to get worse when you use more filters/sorting.
* (Fixed) Lock/Unlock funtionality has made names field unable to be edited


PRE RELEASE ARCHIVE
------------------------------------------------------

Missing functionality I want to add/chage ASAP:
1. (Done) Cap on weekly ontime, attendance
2. A prettier way to handle the tell/whisper option?
3. (Done) Information on the DKP tab that shows the last time that users data was synced successfully
4. (Done) Ability for folks to whisper an editor with "what's my DKP?" and get a whisper reply
5. (Done) Convert Minimap button to use Lib so it can hook into minimap addons (sexymap) better
6. (Done) Restore the missing "has rotated" data from the DKP table"
7. (Done) Restore the colours on the dkp table values that showed increases and decreases
8. (Dropped) A day lock where those buttons only work on raid days at the times we usually use them?
9. (Redundant with new functionality) A warning to the RL/ML that they have to allocate Attendance DKP before people leave the group
10. (Done) Restore the chat window slash commmands
11. (Done) Balance field shouldn't be able to be edited
12. (Done) Add button to RL Tools to allocate bench award
13. (Done) Add to the group builder info window a counter of how many people are in your group/raid and who is not from the selected users
15. (Discuss with Mang) Remove request sync button from editor
16. (Done) Retains the tickboxes on group builder (to prevent loss on a DC), due to this will also have to add a clear (and heck whynot a tick all) option.
17. (Done) Remove funcitonality to check officers... it's not really needed as the addon uses it's own editors lists to determine who shouldnt sync and where data comes from.
18. (Done - add button too) There's no username validation on editor list, would be best to only allow guild users
19. (Done) Improve EE use.
20. (Done) Improve RL tools so you can manually select who to give points to?
21. (Done) Update class/role icons to match the classes but still work on info
22. (Done) Button on ML scoreboard for filter to raid
23. (Done) Refine "Broadcast DKP" button to just people in the group/raid
24. Master switch to turn SYNC off for testing
25. (Done) Option on the Editor tab to set the DKP table version number
26. Revisit audit log now that sync is working
27. (Done) Option on the group builder to select all
28. (Done) A filter to show/hide dkp data of people who have left
29. (Done) SYNC protected to only send data to current guild members
30. Option for the Editors tab that shows how many known addon users
31. (Done) Toggle for Inviter to also show online guildies who aren't on dkp table
32. Option on the RL tools tab that selects raid members
33. (Done) Filter for DKP tab to show current raid members
34. Edit button for DKP tab editors
35. Inactive user option for dkp table (biggie)
36. Mangs changes - (redo RL tools and names of dkp table columns)
37. (Done - because someone speshul wanted this most) Mass Invite functionality
38. (Done) Some way to record players roles


Known Bugs:
1. (Fixed but blurry as all hell) Addon icon not displaying on the addons list
2. (Fixed) Top row record can show above the window when editing + scrolling
3. (Fixed) Audit log is back to showing lots of "unknowns" (display issue the data is there)
4. (Fixed) Minimap button being a twat (needs a full rebuild and Lib file)
5. (Fixed) Clicking away from edit value on DKP table doesnt deslect value (like pressing enter would)
6. (Fixed) On first load the dkp table displays blank, it takes a /reload for the data to display
7. (Fixed) It has lost formatting on the editors list due to fixing name sync issues (likely cosmetic)
8. (Fixed) After fixing 5 the window can nolonger be moved on the DKP tab
9. (Fixed) The group invites spams the user untill they accept the invite rather than once 
10. (Fixed) Personally it feels like there's a loop somewhere in the Editors code that makes it constantly check Editors, which is pointless... needs improved.
11. (Fixed) It can behave very erratically when GL/Editor is AFK or DND.  I know WHY that is but code might be able to be improved to do something else in this situation instead of fail (ie get data from another user?)
12. (Fixed) Broadcast DKP to raid is Alphabetical (Z first) reverse.
13. (Fixed - TLDR wasnt true) No editors online functionality needs imroving, most specifically the red warnings but just more ways for it to sync itself without waiting for manual.  It is possible that this is only true because of the editor sync issue.  Currently it looks like the warnings don't refresh but the addon knows an editor as come online (manual sync works).  So there's a mismatch there that needs looked into.
14. (Fixed) Notes on ML whiteboard don't work and the AI made it worse.
15. (Technically fixed as no longer exists) If previous editor gets rid of addon they get whisper spam from addon users.
16. (Fixed) On DKP whisper reply the Balance is 0
17. (Fixed) Table not refreshing after Add
18. Add button also needs clicked twice (once for defocus and once to activate)
19. (Fixed) Delete functionality causes display issue on dkp table (data is fine)
20. (Fixed?) ML tools table needs to be 'reset' to show changes to dkp table
21. DKP table headers cutoff?  (Rotation)
22. (Fixed) Not a bug but need to change feral dps to a new icon as it's the same as feral tank
23. (Fixed) Missing from group goes off the window on Inviter
24. (Fixed) Broadcast DKP broken
25. (Fixed) The column sizes on ML Scorecard aren't quite right on MS/OS so they highlight in a way that gives me autistic tingles.
26. (Fixed) Raid leader detection wasn't working (only assistant)
27. Force sync to Lunatic did not show her accept in summary
28. Double check summary info on inviter is counting tanks properly
29. When not in group you are not missing in inviter, and ML scorecard shows blank
30. The "Show hidden records" option on DKP tab has the old delete bug where it hides table rows at the end of the list.  Ultimately the DKP table has a redraw logic issue that prevents the table refresh, likely due to duplication of process or incorrect recycling of assets.  Thankfully it doesn't impact the data at all it's just a view issue that seems to get worse when you use more filters/sorting.
7. (Done) ML whiteboard
8. (Abandoned) Filter option for the dkp table
9. Guild crafting info?
10. Options screen to control variables that are currently hard coded
