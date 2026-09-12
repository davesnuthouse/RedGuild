function CreateAuditTab()
    --------------------------------------------------------------------
    -- AUDIT PANEL
    --------------------------------------------------------------------
    do
        local auditScroll = CreateFrame("ScrollFrame", nil, auditPanel, "UIPanelScrollFrameTemplate")
        auditScroll:SetPoint("TOPLEFT", -40, -40)
        auditScroll:SetPoint("BOTTOMRIGHT", -40, 25)

        local auditContent = CreateFrame("Frame", nil, auditScroll)
        auditContent:SetSize(1, 1)
        auditScroll:SetScrollChild(auditContent)

        local MAX_AUDIT_ROWS = 666
        local AUDIT_ROW_HEIGHT = 18

        auditRows = {}

        for i = 1, MAX_AUDIT_ROWS do
            local row = CreateFrame("Frame", nil, auditContent)
            row:SetSize(1, AUDIT_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * AUDIT_ROW_HEIGHT)

            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            local offset = 50

            fs:SetPoint("LEFT", offset + 60, 0)
            fs:SetWidth(740 - offset)
            fs:SetJustifyH("LEFT")
            row.text = fs

            auditRows[i] = row
        end

        auditPanel:SetScript("OnShow", UpdateAuditLog)
    end

end
