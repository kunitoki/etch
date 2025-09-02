-- Arkanoid - Complete game in Lua using Raylib API
-- Both game logic AND rendering happen in this script!

-- Key codes (from raylib)
local KEY_LEFT = 263
local KEY_RIGHT = 262
local KEY_A = 65
local KEY_D = 68
local KEY_SPACE = 32
local KEY_P = 80

-- Color constants
local COLOR_WHITE = rgb(255, 255, 255)
local COLOR_DARKGRAY = rgb(15, 26, 26)
local COLOR_RED = rgb(255, 0, 0)
local COLOR_ORANGE = rgb(255, 165, 0)
local COLOR_YELLOW = rgb(255, 255, 0)
local COLOR_GREEN = rgb(0, 255, 0)
local COLOR_BLUE = rgb(0, 0, 255)

-- Game constants
local PADDLE_WIDTH = 100.0
local PADDLE_HEIGHT = 20.0
local PADDLE_SPEED = 480.0  -- pixels per second

local BALL_RADIUS = 8.0
local BALL_SPEED = 290.0  -- pixels per second
local PADDLE_HIT_SKEW_FACTOR = 8.0  -- how much horizontal speed is added based on hit position

local BRICK_ROWS = 5
local BRICK_COLS = 10
local BRICK_WIDTH = 78.0
local BRICK_HEIGHT = 25.0
local BRICK_PADDING = 2.0

-- Game state (global variables maintained across frames)
paddleX = 400.0
paddleY = 550.0

ballX = 400.0
ballY = 300.0
ballVelX = 4.0
ballVelY = -4.0

bricks = {}
score = 0
gameOver = false
won = false
paused = false

-- Physics accumulator for fixed timestep
accumulator = 0.0

-- Helper functions
local function absFloat(x)
    return math.abs(x)
end

local function minFloat(a, b)
    return math.min(a, b)
end

local function maxFloat(a, b)
    return math.max(a, b)
end

-- Initialize game
function initGame()
    local screenWidth = getScreenWidth()

    paddleX = screenWidth / 2.0
    paddleY = 550.0

    ballX = screenWidth / 2.0
    ballY = 300.0
    ballVelX = BALL_SPEED
    ballVelY = -BALL_SPEED

    -- Initialize bricks
    bricks = {}
    for i = 1, BRICK_ROWS * BRICK_COLS do
        bricks[i] = true
    end

    score = 0
    gameOver = false
    won = false
    accumulator = 0.0
    paused = false

    print("Game initialized!")
end

-- Check collision between ball and rectangle
local function checkBallRectCollision(bx, by, br, rx, ry, rw, rh)
    -- Find closest point on rectangle to ball center
    local closestX = maxFloat(rx, minFloat(bx, rx + rw))
    local closestY = maxFloat(ry, minFloat(by, ry + rh))

    -- Calculate distance
    local distX = bx - closestX
    local distY = by - closestY
    local distSq = distX * distX + distY * distY

    return distSq <= br * br
end

-- Update paddle
local function updatePaddle(dt)
    local screenWidth = getScreenWidth()

    -- Move paddle
    if isKeyDown(KEY_LEFT) or isKeyDown(KEY_A) then
        paddleX = paddleX - PADDLE_SPEED * dt
    end

    if isKeyDown(KEY_RIGHT) or isKeyDown(KEY_D) then
        paddleX = paddleX + PADDLE_SPEED * dt
    end

    -- Clamp to screen
    local halfWidth = PADDLE_WIDTH / 2.0
    if paddleX < halfWidth then
        paddleX = halfWidth
    end

    if paddleX > screenWidth - halfWidth then
        paddleX = screenWidth - halfWidth
    end
end

-- Update ball and physics
local function updateBall(dt)
    local screenWidth = getScreenWidth()
    local screenHeight = getScreenHeight()

    -- Move ball
    ballX = ballX + ballVelX * dt
    ballY = ballY + ballVelY * dt

    -- Wall collisions
    if ballX - BALL_RADIUS <= 0.0 or ballX + BALL_RADIUS >= screenWidth then
        ballVelX = -ballVelX
    end

    -- Ceiling collision
    if ballY - BALL_RADIUS <= 0.0 then
        ballVelY = -ballVelY
    end

    -- Check if ball fell (game over)
    if ballY > screenHeight then
        gameOver = true
    end

    -- Paddle collision
    local paddleLeft = paddleX - PADDLE_WIDTH / 2.0
    if checkBallRectCollision(ballX, ballY, BALL_RADIUS,
                              paddleLeft, paddleY, PADDLE_WIDTH, PADDLE_HEIGHT) then
        ballVelY = -absFloat(ballVelY)

        -- Add spin based on where it hit
        local hitOffset = ballX - paddleX
        ballVelX = hitOffset * PADDLE_HIT_SKEW_FACTOR
    end

    -- Brick collisions
    for row = 0, BRICK_ROWS - 1 do
        for col = 0, BRICK_COLS - 1 do
            local index = row * BRICK_COLS + col + 1  -- Lua tables are 1-indexed

            if bricks[index] then
                local brickX = col * (BRICK_WIDTH + BRICK_PADDING) + BRICK_PADDING
                local brickY = row * (BRICK_HEIGHT + BRICK_PADDING) + BRICK_PADDING + 40.0

                if checkBallRectCollision(ballX, ballY, BALL_RADIUS,
                                          brickX, brickY, BRICK_WIDTH, BRICK_HEIGHT) then
                    bricks[index] = false
                    score = score + 10

                    -- Bounce direction based on hit side
                    local brickCenterX = brickX + BRICK_WIDTH / 2.0
                    local brickCenterY = brickY + BRICK_HEIGHT / 2.0

                    local dx = absFloat(ballX - brickCenterX)
                    local dy = absFloat(ballY - brickCenterY)

                    if dx > dy then
                        ballVelX = -ballVelX
                    else
                        ballVelY = -ballVelY
                    end
                end
            end
        end
    end

    -- Check win condition
    local activeBricks = 0
    for i = 1, BRICK_ROWS * BRICK_COLS do
        if bricks[i] then
            activeBricks = activeBricks + 1
        end
    end

    if activeBricks == 0 then
        won = true
    end
end

-- Render game
local function render()
    local screenWidth = getScreenWidth()
    local screenHeight = getScreenHeight()

    -- beginDrawing()
    clearBackground(COLOR_DARKGRAY)

    -- Draw paddle
    local paddleLeft = math.floor(paddleX - PADDLE_WIDTH / 2.0)
    local paddleY_int = math.floor(paddleY)
    drawRectangle(paddleLeft, paddleY_int, PADDLE_WIDTH, PADDLE_HEIGHT, COLOR_WHITE)

    -- Draw ball
    local ballX_int = math.floor(ballX)
    local ballY_int = math.floor(ballY)
    drawCircle(ballX_int, ballY_int, BALL_RADIUS, COLOR_WHITE)

    -- Draw bricks
    for row = 0, BRICK_ROWS - 1 do
        local color
        if row == 0 then
            color = COLOR_RED
        elseif row == 1 then
            color = COLOR_ORANGE
        elseif row == 2 then
            color = COLOR_YELLOW
        elseif row == 3 then
            color = COLOR_GREEN
        else
            color = COLOR_BLUE
        end

        for col = 0, BRICK_COLS - 1 do
            local index = row * BRICK_COLS + col + 1

            if bricks[index] then
                local x = math.floor(col * (BRICK_WIDTH + BRICK_PADDING) + BRICK_PADDING)
                local y = math.floor(row * (BRICK_HEIGHT + BRICK_PADDING) + BRICK_PADDING + 40.0)
                drawRectangle(x, y, BRICK_WIDTH, BRICK_HEIGHT, color)
            end
        end
    end

    -- Draw score
    drawText("Score: " .. tostring(score), 10, 10, 20, COLOR_WHITE)

    -- Draw pause indicator
    if paused then
        drawText("PAUSED", screenWidth / 2 - 40, 10, 20, COLOR_YELLOW)
    end

    -- Game over / won messages
    if gameOver then
        drawText("GAME OVER!", screenWidth / 2 - 80, screenHeight / 2 - 20, 30, COLOR_RED)
        drawText("Press SPACE to restart", screenWidth / 2 - 110, screenHeight / 2 + 20, 20, COLOR_WHITE)
    elseif won then
        drawText("YOU WIN!", screenWidth / 2 - 60, screenHeight / 2 - 20, 30, COLOR_GREEN)
        drawText("Press SPACE to restart", screenWidth / 2 - 110, screenHeight / 2 + 20, 20, COLOR_WHITE)
    else
        drawText("P: Pause", screenWidth - 100, 10, 15, COLOR_WHITE)
    end

    -- endDrawing()
end

-- Main update function called from C++ every frame
function update()
    local dt_fixed = 1.0 / 60.0  -- 60 FPS physics

    -- Check for pause toggle (P key)
    if isKeyPressed(KEY_P) then
        paused = not paused
    end

    -- Check for restart (Space key)
    if isKeyPressed(KEY_SPACE) then
        if gameOver or won then
            initGame()
        end
    end

    -- Accumulate frame time
    local frameTime = getFrameTime()
    -- Clamp to prevent spiral of death
    local clampedFrameTime = frameTime > 0.25 and 0.25 or frameTime
    accumulator = accumulator + clampedFrameTime

    -- Update game logic in fixed steps
    while accumulator >= dt_fixed do
        if not paused and not gameOver and not won then
            updatePaddle(dt_fixed)
            updateBall(dt_fixed)
        end
        accumulator = accumulator - dt_fixed
    end

    render()
end

-- Initialize on first load
function main()
    initGame()
end