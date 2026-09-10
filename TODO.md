Changes/fixes Required urgently:
* Editor tab rebuild
    - Display dkp versions of each editor
    - Button to poll online users for their addon version and dkp table version
    - Prevent out of date editors from syncing to users completely (requires finishing the editors tab version sync/check code)?
* Reconfirm sync tooltip accuracy
* Warnings on functions that change dkp table version to advise editor if they aren't the highest version (also requires finishing the editors tab version sync/check code)
* Out of guild users?  (specifically being able to add them to dkp table)
* Attendance counter / Last raid (functionality linked to start new DKP week and attend/bench)  Note - will require a dummy date to be added for rows unlikely to ever update
  
Features to deliver ASAP:
* Redo the way DKP table saves to a single button commit (hook into editor rollback funcitonality)
* Revisit audit log completely (might be better after the dkp save change)
* Prevent editors alts from autosync (might be able to use ranks now)
* Add a small sync to check table version between non editors and colour the sync info if out of date (if an editor is not online)
* Show only online filter option on the alt tracker
* DKP Row archive (for users away for a long period) - essentially reinstates previous table tidyup functionality
* (AUC) Bidding popup support for +1 ML

Nice to haves (not essential):
* Full code rebuild (claude)
* Conversion to multi lua file version
