--!strict

local Players = game:GetService("Players")

local WALK_ANIMATION_ID = "rbxassetid://105790090049099"
local RUN_ANIMATION_ID = "rbxassetid://114796763148559"

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid:WaitForChild("Animator")

	local animateScript = character:WaitForChild("Animate")

	if WALK_ANIMATION_ID ~= "" then
		local walkAnim = animateScript:WaitForChild("walk"):WaitForChild("WalkAnim") :: Animation
		walkAnim.AnimationId = WALK_ANIMATION_ID
	end
	if RUN_ANIMATION_ID ~= "" then
		local runAnim = animateScript:WaitForChild("run"):WaitForChild("RunAnim") :: Animation
		runAnim.AnimationId = RUN_ANIMATION_ID
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
