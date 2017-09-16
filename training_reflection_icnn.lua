require 'nn'
require 'optim'
require 'torch'
require 'cutorch'
require 'cunn'
require 'image'
require 'sys'
require 'nngraph'
require 'cudnn'
cudnn.fastest = true
cudnn.benchmark = true

--GPU 4
local function subnet()

  sub = nn.Sequential()

  sub:add(cudnn.SpatialConvolution(64, 64, 3, 3, 1, 1, 1, 1))
  sub:add(cudnn.SpatialBatchNormalization(64))
  sub:add(cudnn.ReLU(true))

  sub:add(cudnn.SpatialConvolution(64, 64, 3, 3, 1, 1, 1, 1))
  sub:add(cudnn.SpatialBatchNormalization(64))

  cont = nn.ConcatTable()
  cont:add(sub)
  cont:add(cudnn.ReLU(true))
  cont:add(nn.Identity())

  return cont
end

--model
mModel = nn.Sequential()

mModel:add(cudnn.SpatialConvolution(4, 64, 3, 3, 1, 1, 1, 1))
mModel:add(cudnn.SpatialBatchNormalization(64))
mModel:add(cudnn.ReLU(true))

mModel:add(cudnn.SpatialConvolution(64, 64, 3, 3, 1, 1, 1, 1))
mModel:add(cudnn.SpatialBatchNormalization(64))
mModel:add(cudnn.ReLU(true))

mModel:add(cudnn.SpatialConvolution(64, 64, 3, 3, 2, 2, 1, 1))
mModel:add(cudnn.SpatialBatchNormalization(64))
mModel:add(cudnn.ReLU(true))

for m = 1,13 do
  mModel:add(subnet())
  mModel:add(nn.CAddTable())
end

grad_b = nn.ConcatTable()
grad_b:add(nn.Identity())
grad_b:add(nn.ComputeXGrad())
grad_b:add(nn.ComputeYGrad())

mModel:add(cudnn.SpatialFullConvolution(64, 64, 4, 4, 2, 2, 1, 1))
mModel:add(cudnn.SpatialBatchNormalization(64))
mModel:add(cudnn.ReLU(true))

mModel:add(cudnn.SpatialConvolution(64, 64, 3, 3, 1, 1, 1, 1))
mModel:add(cudnn.SpatialBatchNormalization(64))
mModel:add(cudnn.ReLU(true))

mModel:add(cudnn.SpatialConvolution(64, 3, 1, 1))
mModel:add(grad_b)

model = nn.Sequential()
model:add(mModel)

criterion = nn.ParallelCriterion():add(nn.MSECriterion(),0.2):add(nn.L1Criterion(),0.4):add(nn.L1Criterion(),0.4)
model = model:cuda()
criterion = criterion:cuda()

model_edge = nn.computeEdge(1)

for i,module in ipairs(model:listModules()) do
   local m = module
   if m.__typename == 'cudnn.SpatialConvolution' or m.__typename == 'cudnn.SpatialFullConvolution' then
      local stdv = math.sqrt(12/(m.nInputPlane*m.kH*m.kW + m.nOutputPlane*m.kH*m.kW))
      m.weight:uniform(-stdv, stdv)
      m.bias:zero()
   end
   if m.__typename == 'cudnn.SpatialBatchNormalization' then
      m.weight:fill(1)
      m.bias:zero()
   end
end


postfix = 'reflection_i_cnn'
max_iters = 40
batch_size = 2

model:training()
collectgarbage()

parameters, gradParameters = model:getParameters()

sgd_params = {
  learningRate = 1e-2,
  learningRateDecay = 1e-8,
  weightDecay = 0.0005,
  momentum = 0.9,
  dampening = 0,
  nesterov = true
}

adam_params = {
  learningRate = 1e-2,
  weightDecay = 0.0005,
  beta1 = 0.9,
  beta2 = 0.999
}

rmsprop_params = {
  learningRate = 1e-2,
  weightDecay = 0.0005,
  alpha = 0.9
}

-- Log results to files
savePath = '/mnt/codes/reflection/models/'

local file = '/mnt/codes/reflection/models/training_reflection_ecnn.lua'
local f = io.open(file, "rb")
local line = f:read("*all")
f:close()
print('*******************train file*******************')
print(line)
print('*******************train file*******************')

local file = '/mnt/data/VOC2012_224_train_png.txt'
local trainSet = {}
local f = io.open(file, "rb")
while true do
  local line = f:read()
  if line == nil then break end
  table.insert(trainSet, line)
end
f:close()
local trainsetSize = #trainSet
if trainsetSize % 2 == 1 then
  trainsetSize = trainsetSize - 1
end

local file = '/mnt/data/VOC2012_224_test_png.txt'
local testSet = {}
local f = io.open(file, "rb")
while true do
  local line = f:read()
  if line == nil then break end
  table.insert(testSet, line)
end
f:close()
local testsetSize = #testSet

local iter = 0
local epoch_judge = false
step = function(batch_size)
  local testCount = 1
  local current_loss = 0
  local current_testloss = 0
  local count = 0
  local testcount = 0
  batch_size = batch_size or 4
  local order = torch.randperm(trainsetSize)

  for t = 1,trainsetSize,batch_size do
    iter = iter + 1
    local size = math.min(t + batch_size, trainsetSize + 1) - t

    local feval = function(x_new)
      -- reset data
      if parameters ~= x_new then parameters:copy(x_new) end
      gradParameters:zero()

      local loss = 0
      for i = 1,size,2 do
        local inputFile1 =  trainSet[order[t+i-1]]
        local inputFile2 = trainSet[order[t+i]]
        local tempInput1 = image.load(inputFile1)
        local tempInput2 = image.load(inputFile2)
        local height = tempInput1:size(2)
        local width = tempInput1:size(3)
        local input1 = torch.CudaTensor(1, 3, height, width)
        local input = torch.CudaTensor(1, 3, height, width)
        local inputs = torch.CudaTensor(1, 4, height, width)

        local window = image.gaussian(11,torch.uniform(2,5)/11)
        window = window:div(torch.sum(window))
        local tempInput2 = image.convolve(tempInput2, window, 'same')

        local tempInput1 = tempInput1:cuda()
        local tempInput2 = tempInput2:cuda()
        tempInput = torch.add(tempInput1,tempInput2)
        if tempInput:max() > 1 then
          local label_ge1 = torch.gt(tempInput,1)
          tempInput2 = tempInput2 - torch.mean((tempInput-1)[label_ge1],1)[1]*1.3
          tempInput2 = torch.clamp(tempInput2,0,1)
          tempInput = torch.add(tempInput1,tempInput2)
          tempInput = torch.clamp(tempInput,0,1)
        end

        input1[1] = tempInput1
        input[1] = tempInput
        input1 = input1 * 255
        input = input * 255
        inputs[{{},{1,3},{},{}}] = input
        inputs[{{},{4},{},{}}] = model_edge:forward(input1)
        inputs = inputs - 115
        local xGrad1 = input1:narrow(4,2,width-1) - input1:narrow(4,1,width-1)
        local yGrad1 = input1:narrow(3,2,height-1) - input1:narrow(3,1,height-1)
        local labels = {input1,xGrad1,yGrad1}

        local pred = model:forward(inputs)
        local tempLoss =  criterion:forward(pred, labels)
        loss = loss + tempLoss
        local grad = criterion:backward(pred, labels)

        model:backward(inputs, grad)
      end
      gradParameters:div(size/2)
      loss = loss/(size/2)

      return loss, gradParameters
    end
    
    if epoch_judge then
      adam_params.learningRate = adam_params.learningRate*0.1
      _, fs, adam_state_save = optim.adam_state(feval, parameters, adam_params, adam_params)
      epoch_judge = false
    else
      _, fs, adam_state_save = optim.adam_state(feval, parameters, adam_params)
    end

    count = count + 1
    current_loss = current_loss + fs[1]
    print(string.format('Iter: %d Current loss: %4f', iter, fs[1]))

    if iter % 20 == 0 then
      local loss = 0
      for i = 1,size,2 do
        local inputFile1 = testSet[testCount]
        local inputFile2 = testSet[testCount+1]
        local tempInput1 = image.load(inputFile1)
        local tempInput2 = image.load(inputFile2)
        local height = tempInput1:size(2)
        local width = tempInput1:size(3)
        local input1 = torch.CudaTensor(1, 3, height, width)
        local input = torch.CudaTensor(1, 3, height, width)
        local inputs = torch.CudaTensor(1, 4, height, width)

        local window = image.gaussian(11,torch.uniform(2,5)/11)
        window = window:div(torch.sum(window))
        local tempInput2 = image.convolve(tempInput2, window, 'same')

        local tempInput1 = tempInput1:cuda()
        local tempInput2 = tempInput2:cuda()
        tempInput = torch.add(tempInput1,tempInput2)
        if tempInput:max() > 1 then
          local label_ge1 = torch.gt(tempInput,1)
          tempInput2 = tempInput2 - torch.mean((tempInput-1)[label_ge1],1)[1]*1.3
          tempInput2 = torch.clamp(tempInput2,0,1)
          tempInput = torch.add(tempInput1,tempInput2)
          tempInput = torch.clamp(tempInput,0,1)
        end

        input1[1] = tempInput1
        input[1] = tempInput
        input1 = input1 * 255
        input = input * 255
        inputs[{{},{1,3},{},{}}] = input
        inputs[{{},{4},{},{}}] = model_edge:forward(input1)
        inputs = inputs - 115
        local xGrad1 = input1:narrow(4,2,width-1) - input1:narrow(4,1,width-1)
        local yGrad1 = input1:narrow(3,2,height-1) - input1:narrow(3,1,height-1)
        local labels = {input1,xGrad1,yGrad1}

        local pred = model:forward(inputs)
        local tempLoss =  criterion:forward(pred, labels)
        loss = loss + tempLoss
        testCount = testCount + 2
      end
      loss = loss/(size/2)
      testcount = testcount + 1
      current_testloss = current_testloss + loss

      print(string.format('TestIter: %d Current loss: %4f', iter, loss))
    end
  end

  -- normalize loss
  return current_loss / count, current_testloss / testcount
end

netfiles = '/mnt/codes/reflection/models/'
timer = torch.Timer()
do
  for i = 1,max_iters do
    localTimer = torch.Timer()
    local loss,testloss = step(batch_size,i)
    if i == 35 then
      epoch_judge = true
    end
    print(string.format('Epoch: %d Current loss: %4f', i, loss))
    print(string.format('Epoch: %d Current test loss: %4f', i, testloss))

    local filename = string.format('%smodel_%s_%d.net',netfiles,postfix,i)
    model:clearState()
    torch.save(filename, model)
    local filename = string.format('%sstate_%s_%d.t7',netfiles,postfix,i)
    torch.save(filename, adam_state_save)
    print('Time elapsed (epoch): ' .. localTimer:time().real/(3600) .. ' hours')
  end
end
print('Time elapsed: ' .. timer:time().real/(3600*24) .. ' days')
