extends Node2D

const BrickGroupLibrary = preload("res://games/Arkaruga/Scripts/Arkaruga-BrickGroupLibrary.gd")
const Types = preload("res://games/Arkaruga/Scripts/Arkaruga-Types.gd")
const InitialEasyGroupSpawnCount : int = 2
const InitialRandomGroupSpawnCount : int = 5
const ConfigSavePath : String = "user://arkaruga.cfg"
const HighScoreSaveCategory : String = "HighScores"

export (Resource) var brickGroupLibrary
export (PackedScene) var ballScene
export (int) var startLives = 5
export var secondsToMaxSpeed = 360
export var timeRatioLostOnDeath = .33
export (int) var bonusLifePoints = 100
export (int) var multiballCombo = 10
export (float) var multiballAngleOffset = 45.0
export (float) var mediumGroupChanceIncrement = .5
export (float) var hardGroupChanceIncrement = .1

onready var uiManager = get_node("%UILayer")
onready var paddle = get_node("%Paddle")
onready var particlesContainer = get_node("%ParticlesContainer")
onready var ballContainer = get_node("%BallContainer")
onready var brickContainer = get_node("%BrickContainer")
onready var brickGroupSpawnPoint = get_node("%BrickGroupSpawnPoint")

onready var _startGameTimer : Timer = $StartGameTimer
onready var _endGameTimer : Timer = $EndGameTimer
onready var _lostBallTimer : Timer = $LostBallTimer
onready var _musicNode : Node2D = $Music
onready var _gameOverSFX : AudioStreamPlayer = $SFX/GameOverSFX
onready var _countdownSFX : AudioStreamPlayer = $SFX/CountdownSFX
onready var _countdownGoSFX : AudioStreamPlayer = $SFX/CountdownGoSFX
onready var _multiballSFX : AudioStreamPlayer = $SFX/MultiballSFX
onready var _loseLifeSFX : AudioStreamPlayer = $SFX/LoseLifeSFX
onready var _bonusLifeSFX : AudioStreamPlayer = $SFX/BonusLifeSFX
onready var _colorSwapSFX : AudioStreamPlayer = $SFX/ColorSwapSFX

var activeColor = Types.ElementColor.BLUE

var _isGameRunning = false
var _livesRemaining : int
var _score : int
var _combo : int
var _totalGameDuration : float
var _gameDurationForSpeed : float
var _lastSpawnedBrickGroup : Node2D
var _mediumGroupChance : float
var _hardGroupChance : float
var _bestScore : int
var _bestTime : float
var _activeMusic : String

func _ready():
	_loadHighScores()
	setActiveColor(Types.ElementColor.GREEN)
	
	# set our initial lives so the UI fills out
	_livesRemaining = startLives
	
	playStartScreenMusic()
	
func _input(event):
	if event.is_action_pressed("action1"):
		if _isGameRunning:
			swapActiveColor()
		
func _process(delta):
	if _isGameRunning && getAnyBallsActive():
		_totalGameDuration += delta
		_gameDurationForSpeed += delta
	
	_processUI(delta)
	
func _processUI(_delta):
	if !uiManager:
		return
	
	uiManager.setScoreValue(_score)
	uiManager.setComboValue(_combo)
	uiManager.setLives(_livesRemaining)
	uiManager.setTime(int(_totalGameDuration))
	
func onBallLaunched(_ball):
	playGameplayMusic()
		
func onBallLost(_ball):
	# this can get called while the scene is being torn down
	if !is_inside_tree():
		return
	
	# reset our combo whenever a ball goes offscreen
	_combo = 0
	_loseLifeSFX.play() 
	
	# there are no balls left -- respawn!
	if !getAnyBallsActive():
		if _livesRemaining > 0:
			_lostBallTimer.start()
			yield(_lostBallTimer, "timeout")
			loseLife()
			_respawnBall()
		else:
			endGame()
			
func onBrickSpawnAreaClear(brickGroup : Node2D):
	# this can get called while the scene is being torn down
	if !is_inside_tree():
		return
	
	if brickGroup == _lastSpawnedBrickGroup && is_instance_valid(brickGroup):
			call_deferred("_spawnRandomBrickGroup")
		
func getAnyBallsActive():
	var balls = get_tree().get_nodes_in_group("Balls")
	for ball in balls:
		if ball.getIsActive():
			return true
			
	return false
	
func startGame():
	if uiManager:
		uiManager.setStartScreenVisible(false)
		uiManager.setSidebarResultsVisible(false)
		uiManager.setBestScoreVisible(false)
		uiManager.setBestTimeVisible(false)
		
	randomize()
		
	_lastSpawnedBrickGroup = null
	_clearBricks()
	
	for n in InitialEasyGroupSpawnCount:
		_spawnEasyBrickGroup()
	
	for n in InitialRandomGroupSpawnCount:
		_spawnRandomBrickGroup()
	
	_startGameTimer.start()
	yield(_startGameTimer, "timeout")
	
	_isGameRunning = true
	_livesRemaining = startLives
	_totalGameDuration = 0
	_gameDurationForSpeed = 0
	_score = 0
	_combo = 0
	_mediumGroupChance = 0
	_hardGroupChance = 0
	
	# spend a life on the initial ball so the UI matches the desired count
	loseLife()
	_respawnBall()
	
func endGame():
	_isGameRunning = false
	
	_endGameTimer.start()
	yield(_endGameTimer, "timeout")
	
	_gameOverSFX.play()
	playEndScreenMusic()
	
	uiManager.setEndScreenVisible(true)
	uiManager.setSidebarResultsVisible(true)
	
	uiManager.setBestScoreVisible(_score > _bestScore)
	uiManager.setBestTimeVisible(_totalGameDuration > _bestTime)
	
	_bestScore = max(_bestScore, _score)
	_bestTime = max(_totalGameDuration, _bestTime)
	
	_saveHighScores()
	
func closeEndGameScreen():
	uiManager.setStartScreenVisible(true)
	uiManager.setEndScreenVisible(false)
	playStartScreenMusic()
	
func addScore(points : int):
	var prevLiveIncrement = _score / bonusLifePoints
	_score += points
	
	if _score / bonusLifePoints > prevLiveIncrement:
		_bonusLifeSFX.play()
		gainLife()
		if uiManager:
			uiManager.playToast("BALL GET!")
		
	
func addCombo(ball, value : int = 1):
	var comboForNextMultiball = getComboForNextMultiball()
	_combo += value
	
	if _combo >= comboForNextMultiball:
		_multiballSFX.play()
		_spawnMultiball(ball)
		if uiManager:
			uiManager.playToast("MULTI BALL!")

func resetCombo():
	_combo = 0
	
func loseLife(): 
	if _livesRemaining > 0:
		_livesRemaining -= 1
		# slow the game down after losing a life
		_gameDurationForSpeed = max(0.0, _gameDurationForSpeed * (1.0 - timeRatioLostOnDeath))
	
func gainLife():
	_livesRemaining += 1

func swapActiveColor():
	match activeColor:
		Types.ElementColor.BLUE:
			setActiveColor(Types.ElementColor.GREEN)
		Types.ElementColor.GREEN:
			setActiveColor(Types.ElementColor.BLUE)
			
	_colorSwapSFX.play()

func setActiveColor(color: int):
	activeColor = color
	get_tree().call_group("Colorized", "onActiveColorChanged", color)

func getIsGameRunning() -> bool:
	return _isGameRunning

func getSpeedModifierRatio() -> float:
	return inverse_lerp(0.0, secondsToMaxSpeed, _gameDurationForSpeed)

func getComboForNextMultiball() -> int:
	var ballCount = get_tree().get_nodes_in_group("Balls").size()
	var minCombo = multiballCombo * max(1, ballCount)
	return minCombo

func _respawnBall():
	var ballInstance = ballScene.instance()
	ballInstance.attachToPaddle(paddle)
	ballInstance.startLaunchTimer()
	
func _spawnMultiball(ball):
	var newBall = ballScene.instance()
	ballContainer.add_child(newBall)
	newBall.global_position = ball.global_position
	var velocity = -ball.velocity
	var angleOffset = multiballAngleOffset
	if randf() > .5:
		angleOffset *= -1
	velocity = velocity.rotated(deg2rad(angleOffset))
	newBall.velocity = velocity

func _clearBricks():
	var brickGroups = get_tree().get_nodes_in_group("BrickGroups")
	for group in brickGroups:
		group.queue_free()

	var bricks = get_tree().get_nodes_in_group("Bricks")	
	for brick in bricks:
		brick.queue_free()
		
func _spawnRandomBrickGroup():
	var library : BrickGroupLibrary = brickGroupLibrary
	var group = null
	if randf() < _hardGroupChance:
		group = library.getRandomHardGroup()
		_hardGroupChance -= 1
	elif randf() < _mediumGroupChance:
		group = library.getRandomMedGroup()
		_mediumGroupChance -= 1
	else:
		group = library.getRandomEasyGroup()
		_mediumGroupChance += mediumGroupChanceIncrement
		_hardGroupChance += hardGroupChanceIncrement
		
	_spawnBrickGroup(group)
	
func _spawnEasyBrickGroup():
	var library : BrickGroupLibrary = brickGroupLibrary
	var group = library.getRandomEasyGroup()
		
	_spawnBrickGroup(group)
	
	
func _spawnBrickGroup(group):
	var spawnPosition = brickGroupSpawnPoint.global_position
	if _lastSpawnedBrickGroup:
		spawnPosition = _lastSpawnedBrickGroup.getNextGroupSpawnGlobalPosition()
	
	var groupInstance = group.instance()
	groupInstance.global_position = spawnPosition
	brickContainer.add_child(groupInstance)
	
	_lastSpawnedBrickGroup = groupInstance

func _loadHighScores():
	var config = ConfigFile.new()
	var err = config.load(ConfigSavePath)

	if err == OK:
		_bestScore = config.get_value(HighScoreSaveCategory, "Score")
		_bestTime = config.get_value(HighScoreSaveCategory, "Time")
	else:
		_bestScore = 0
		_bestTime = 0

func _saveHighScores():
	var config = ConfigFile.new()
	config.set_value(HighScoreSaveCategory, "Score", _bestScore)
	config.set_value(HighScoreSaveCategory, "Time", _bestTime)
	config.save(ConfigSavePath)
	pass
	
func playParticles(particles : PackedScene, position : Vector2):
	if !particles:
		return
	
	var instance = particles.instance()
	particlesContainer.add_child(instance)
	instance.global_position = position

func playCountdownSFX():
	_countdownSFX.play()
	
func playCountdownGoSFX():
	_countdownGoSFX.play()
	
func playStartScreenMusic():
	_playMusic("StartScreenMusic")

func playEndScreenMusic():
	_playMusic("EndScreenMusic")
	
func playGameplayMusic():
	_playMusic("GameplayMusic")
	
func _playMusic(music):
	if music == _activeMusic:
		return
	
	for node in _musicNode.get_children():
		if node is AudioStreamPlayer:
			if node.name == music:
				node.play()
			else:
				node.stop()
				
	_activeMusic = music
	
	
