RandomTreeGrowth = {}

function RandomTreeGrowth:updateTrees(originalFunction, dt, dtGame)
    local treesData = self.treesData
    treesData.updateDtGame = treesData.updateDtGame + dtGame
    
    -- update all 60 ingame minutes
    if treesData.updateDtGame > 1000*60*60 then
        self:cleanupDeletedTrees()

        local time = treesData.updateDtGame
        local dtHours = time / (1000*60*60) * g_currentMission.environment.timeAdjustment
        treesData.updateDtGame = 0
        local numGrowingTrees = #treesData.growingTrees

        Logging.info("Update time!")

        local i = 1
        while i <= numGrowingTrees do
            local tree = treesData.growingTrees[i]
            
            Logging.info("I'm a growing tree")
            -- Check if the tree has been cut in the mean time
            if getChildAt(tree.node, 0) ~= tree.origSplitShape then
                -- The tree has been cut, it will not grow anymore
                table.remove(treesData.growingTrees, i)
                numGrowingTrees = numGrowingTrees - 1
                tree.origSplitShape = nil
                table.insert(treesData.splitTrees, tree)
            else
                local treeTypeDesc = self.indexToTreeType[tree.treeType]
                local numTreeFiles = table.getn(treeTypeDesc.treeFilenames)
                local growthState = tree.growthState
                -- TODO check for collisions
                local oldGrowthStateI = math.floor(growthState * (numTreeFiles - 1)) + 1
                growthState = math.min(growthState + dtHours / treeTypeDesc.growthTimeHours, 1)
                local growthStateI = math.floor(growthState * (numTreeFiles - 1)) + 1

                tree.growthState = growthState
                local noMoreGrowing = false

                if oldGrowthStateI ~= growthStateI and treeTypeDesc.treeFilenames[oldGrowthStateI] ~= treeTypeDesc.treeFilenames[growthStateI] then
                    
                    Logging.info("New stage, let's gooooooo")
                    
                    -- Delete the old tree
                    delete(tree.node)

                    if not tree.hasSplitShapes then
                        self.numTreesWithoutSplits = math.max(self.numTreesWithoutSplits - 1, 0)
                        treesData.numTreesWithoutSplits = math.max(treesData.numTreesWithoutSplits - 1, 0)
                    end

                    -- Create the new tree
                    local treeId, splitShapeFileId = self:loadTreeNode(treeTypeDesc, tree.x, tree.y, tree.z, tree.rx, tree.ry, tree.rz, growthStateI, -1)

                    g_server:broadcastEvent(TreeGrowEvent.new(tree.treeType, tree.x, tree.y, tree.z, tree.rx, tree.ry, tree.rz, tree.growthState, splitShapeFileId, tree.splitShapeFileId))

                    tree.origSplitShape = getChildAt(treeId, 0)
                    tree.splitShapeFileId = splitShapeFileId
                    tree.hasSplitShapes = getFileIdHasSplitShapes(splitShapeFileId)
                    tree.node = treeId

                    -- update collision map
                    local range = 2.5
                    local x, _, z = getWorldTranslation(treeId)
                    g_densityMapHeightManager:setCollisionMapAreaDirty(x-range, z-range, x+range, z+range, true)
                    g_currentMission.aiSystem:setAreaDirty(x-range, x+range, z-range, z+range)

                    if not tree.hasSplitShapes then
                        self.numTreesWithoutSplits = self.numTreesWithoutSplits + 1
                        treesData.numTreesWithoutSplits = treesData.numTreesWithoutSplits + 1
                    end

                    if growthStateI == 1 then
                        -- Sapling, let it grow
                    elseif growthStateI == 2 then 
                        -- First stage, always low chance
                        noMoreGrowing = math.random(1, 100) <= 5
                    else
                        -- Stages beyond sapling and first
                        local remainingStages = numTreeFiles - 2
                        
                        -- Just to be safe, but should never be 0 since Giant's logic
                        -- would have removed it from growingTrees in stage 1
                        if  remainingStages > 0 then
                            
                            -- We want equal likelyhood of each stage
                            noMoreGrowing = math.random(1, 100) <= (100/remainingStages)
                        end
                    end
                end

                if noMoreGrowing then Logging.info("Stage " .. growthStateI - 1 .. " tree randomly stopped growing") end
                if growthStateI >= numTreeFiles then Logging.info("Final stage " .. growthStateI - 1 .. " reached") end

                if growthStateI >= numTreeFiles or noMoreGrowing then
                    -- Reached max grow level, can't grow anymore
                    table.remove(treesData.growingTrees, i)
                    numGrowingTrees = numGrowingTrees-1
                    tree.origSplitShape = nil
                    table.insert(treesData.splitTrees, tree)
                else
                    i = i+1
                end
            end
        end
    end

    local curTime = g_currentMission.time
    for joint in pairs(treesData.treeCutJoints) do
        if joint.destroyTime <= curTime or not entityExists(joint.shape) then
            removeJoint(joint.jointIndex)
            treesData.treeCutJoints[joint] = nil
        else
            local x1,y1,z1 = localDirectionToWorld(joint.shape, joint.lnx, joint.lny, joint.lnz)
            if x1*joint.nx + y1*joint.ny + z1*joint.nz < joint.maxCosAngle then
                removeJoint(joint.jointIndex)
                treesData.treeCutJoints[joint] = nil
            end
        end
    end

    if self.loadTreeTrunkData ~= nil then
        self.loadTreeTrunkData.framesLeft = self.loadTreeTrunkData.framesLeft - 1
        -- first cut and remove upper part of tree
        if self.loadTreeTrunkData.framesLeft == 1 then
            local nx,ny,nz = 0, 1, 0
            local yx,yy,yz = -1, 0, 0
            local x,y,z = self.loadTreeTrunkData.x+1, self.loadTreeTrunkData.y, self.loadTreeTrunkData.z-1

            self.loadTreeTrunkData.parts = {}

            local shape = self.loadTreeTrunkData.shape
            if shape ~= nil and shape ~= 0 then
                self.shapeBeingCut = shape
                splitShape(shape, x,y+self.loadTreeTrunkData.length+self.loadTreeTrunkData.offset,z, nx,ny,nz, yx,yy,yz, 4, 4, "cutTreeTrunkCallback", self)
                self:removingSplitShape(shape)
                for _, p in pairs(self.loadTreeTrunkData.parts) do
                    if p.isAbove then
                        delete(p.shape)
                    else
                        self.loadTreeTrunkData.shape = p.shape
                    end
                end
            end

        -- second cut lower part to get final length
        elseif self.loadTreeTrunkData.framesLeft == 0 then
            local nx,ny,nz = 0, 1, 0
            local yx,yy,yz = -1, 0, 0
            local x,y,z = self.loadTreeTrunkData.x+1, self.loadTreeTrunkData.y, self.loadTreeTrunkData.z-1

            self.loadTreeTrunkData.parts = {}
            local shape = self.loadTreeTrunkData.shape
            if shape ~= nil and shape ~= 0 then
                splitShape(shape, x,y+self.loadTreeTrunkData.offset,z, nx,ny,nz, yx,yy,yz, 4, 4, "cutTreeTrunkCallback", self)
                local finalShape = nil
                for _, p in pairs(self.loadTreeTrunkData.parts) do
                    if p.isBelow then
                        delete(p.shape)
                    else
                        finalShape = p.shape
                    end
                end
                -- set correct rotation of final chunk
                if finalShape ~= nil then
                    if self.loadTreeTrunkData.delimb then
                        removeSplitShapeAttachments(finalShape, x,y+self.loadTreeTrunkData.offset,z, nx,ny,nz, yx,yy,yz, self.loadTreeTrunkData.length, 4, 4)
                    end

                    removeFromPhysics(finalShape)
                    setDirection(finalShape, 0, -1, 0, self.loadTreeTrunkData.dirX, self.loadTreeTrunkData.dirY, self.loadTreeTrunkData.dirZ)
                    addToPhysics(finalShape)
                else
                    Logging.error("Unable to cut tree trunk with length '%s'. Try using a different value", self.loadTreeTrunkData.length)
                end
            end

            self.loadTreeTrunkData = nil
        end
    end

    if self.commandCutTreeData ~= nil then
        if #self.commandCutTreeData.trees > 0 then
            local treeId = self.commandCutTreeData.trees[1]

            local x, y, z = getWorldTranslation(treeId)
            local localX, localY, localZ = worldToLocal(treeId, x, y + 0.5, z)
            local cx, cy, cz = localToWorld(treeId, localX - 2, localY, localZ - 2)
            local nx, ny, nz = localDirectionToWorld(treeId, 0, 1, 0)
            local yx, yy, yz = localDirectionToWorld(treeId, 0, 0, 1)

            self.commandCutTreeData.shapeBeingCut = treeId
            Logging.info("Cut tree '%s' (%d left)", getName(treeId), #self.commandCutTreeData.trees - 1)
            splitShape(treeId, cx, cy, cz, nx, ny, nz, yx, yy, yz, 4, 4, "onTreeCutCommandSplitCallback", self)

            table.remove(self.commandCutTreeData.trees, 1)
        else
            self.commandCutTreeData = nil
        end
    end

    self.updateDecayDtGame = self.updateDecayDtGame + dtGame
    if self.updateDecayDtGame > TreePlantManager.DECAY_INTERVAL then
        -- Update seasonal state of active split shapes
        for shape, data in pairs(self.activeDecayingSplitShapes) do
            if not entityExists(shape) then
                self.activeDecayingSplitShapes[shape] = nil
            elseif data.state > 0 then
                local newState = math.max(data.state - TreePlantManager.DECAY_DURATION_INV * self.updateDecayDtGame, 0)

                self:setSplitShapeLeafScaleAndVariation(shape, newState, data.variation)
                self.activeDecayingSplitShapes[shape].state = newState
            end
        end

        self.updateDecayDtGame = 0
    end
end

TreePlantManager.updateTrees = Utils.overwrittenFunction(TreePlantManager.updateTrees, RandomTreeGrowth.updateTrees)
