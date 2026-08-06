--!strict

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local WALK_SPEED = 16
local RUN_SPEED = 26
local WALK_ANIMATION_ID = "rbxassetid://105790090049099"
local RUN_ANIMATION_ID = "rbxassetid://114796763148559"

local player = Players.LocalPlayer :: Player
local isSprinting = false
local walkTrack: AnimationTrack? = nil
local runTrack: AnimationTrack? = nil

local function loadTrack(humanoid: Humanoid, animationId: string): AnimationTrack?
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		warn("[SprintToggle] Failed to load animation: " .. tostring(trackOrError))
		return nil
	end
	local track = trackOrError :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Action
	return track
end

-- The default Animate script's own locomotion track plays at Core priority,
-- which always wins visually over anything we play -- so we stop everything
-- except our own two tracks every time movement state changes, and drive
-- walk/run entirely ourselves from here on (Animate still handles idle/jump/etc).
local function suppressOtherTracks(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		if track ~= walkTrack and track ~= runTrack then
			track:Stop(0)
		end
	end
end

local function updateLocomotion(humanoid: Humanoid, speed: number)
	if speed <= 0.01 then
		if walkTrack and walkTrack.IsPlaying then
			walkTrack:Stop(0.1)
		end
		if runTrack and runTrack.IsPlaying then
			runTrack:Stop(0.1)
		end
		return
	end

	suppressOtherTracks(humanoid)
	local desired = isSprinting and runTrack or walkTrack
	local other = isSprinting and walkTrack or runTrack

	if other and other.IsPlaying then
		other:Stop(0.1)
	end
	if desired and not desired.IsPlaying then
		desired:Play(0.1)
	end
end

local function setSprinting(sprinting: boolean)
	isSprinting = sprinting
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = sprinting and RUN_SPEED or WALK_SPEED
	local estimatedSpeed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	updateLocomotion(humanoid, estimatedSpeed)
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then
		return
	end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		setSprinting(not isSprinting)
	end
end)

player.CharacterAdded:Connect(function(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	walkTrack = loadTrack(humanoid, WALK_ANIMATION_ID)
	runTrack = loadTrack(humanoid, RUN_ANIMATION_ID)
	setSprinting(false) -- always respawn at walking speed, not however sprint was left before death

	humanoid.Running:Connect(function(speed: number)
		updateLocomotion(humanoid, speed)
	end)
end)
