"""

julia resnet.jl image-file-or-url

This example implements the ResNet-50, ResNet-101 and ResNet-152 models from
'Deep Residual Learning for Image Regocnition', Kaiming He, Xiangyu Zhang,
Shaoqing Ren, Jian Sun, arXiv technical report 1512.03385, 2015.

* Paper url: https://arxiv.org/abs/1512.03385
* Project page: https://github.com/KaimingHe/deep-residual-networks
* MatConvNet weights used here: http://www.vlfeat.org/matconvnet/pretrained

"""
module ResNet
using Knet, CUDA, ArgParse
include(Knet.dir("data","imagenet.jl"))

const modelurl = "http://www.vlfeat.org/matconvnet/models/imagenet-resnet-101-dag.mat"
const imgurl = "https://github.com/BVLC/caffe/raw/master/examples/images/cat.jpg"

function main(args)
    s = ArgParseSettings()
    s.description = "resnet.jl (c) Ilker Kesen, 2017. Classifying images with Deep Residual Networks."

    @add_arg_table s begin
        ("image"; default=imgurl; help="Image file or URL.")
        ("--model"; default="imagenet-resnet-101-dag"; help="resnet model name")
        ("--top"; default=5; arg_type=Int; help="Display the top N classes")
        ("--atype"; default="$(Knet.array_type[])"; help="array and float type to use")
    end

    isa(args, AbstractString) && (args=split(args))
    if in("--help", args) || in("-h", args)
        ArgParse.show_help(s; exit_when_done=false)
        return
    end
    println(s.description)
    o = parse_args(args, s; as_symbols=true)
    println("opts=",[(k,v) for (k,v) in o]...)
    atype = eval(Meta.parse(o[:atype]))
    model = matconvnet(o[:model])
    avgimg = model["meta"]["normalization"]["averageImage"]
    avgimg = convert(Array{Float32}, avgimg)
    description = model["meta"]["classes"]["description"]
    w, ms = get_params(model["params"], atype)

    @info("Reading $(o[:image])")
    img = imgdata(o[:image], avgimg)
    img = convert(atype, img)

    # get model by length of parameters
    modeldict = Dict(
        162 => (resnet50, "resnet50"),
        314 => (resnet101, "resnet101"),
        467 => (resnet152, "resnet152"))
    !haskey(modeldict, length(w)) && error("wrong resnet MAT file")
    resnet, name = modeldict[length(w)]

    @info("Classifying with $name")
    @time y1 = resnet(w,img,ms)
    z1 = vec(Array(y1))
    s1 = sortperm(z1,rev=true)
    p1 = exp.(logp(z1))
    display(hcat(p1[s1[1:o[:top]]], description[s1[1:o[:top]]]))
    println()
end

# mode, 0=>train, 1=>test
function resnet50(w,x,ms; mode=1)
    # layer 1
    conv1  = conv4(w[1],x; padding=3, stride=2) .+ w[2]
    bn1    = batchnorm(w[3:4],conv1,ms; mode=mode)
    pool1  = pool(bn1; window=3, stride=2)

    # layer 2,3,4,5
    r2 = reslayerx5(w[5:34], pool1, ms; strides=[1,1,1,1], mode=mode)
    r3 = reslayerx5(w[35:73], r2, ms; mode=mode)
    r4 = reslayerx5(w[74:130], r3, ms; mode=mode) # 5
    r5 = reslayerx5(w[131:160], r4, ms; mode=mode)

    # fully connected layer
    pool5  = pool(r5; stride=1, window=7, mode=2)
    fc1000 = w[161] * mat(pool5) .+ w[162]
end

# mode, 0=>train, 1=>test
function resnet101(w,x,ms; mode=1)
    # layer 1
    conv1 = reslayerx1(w[1:3],x,ms; padding=3, stride=2, mode=mode)
    pool1 = pool(conv1; window=3, stride=2)

    # layer 2,3,4,5
    r2 = reslayerx5(w[4:33], pool1, ms; strides=[1,1,1,1], mode=mode)
    r3 = reslayerx5(w[34:72], r2, ms; mode=mode)
    r4 = reslayerx5(w[73:282], r3, ms; mode=mode)
    r5 = reslayerx5(w[283:312], r4, ms; mode=mode)

    # fully connected layer
    pool5  = pool(r5; stride=1, window=7, mode=2)
    fc1000 = w[313] * mat(pool5) .+ w[314]
end

# mode, 0=>train, 1=>test
function resnet152(w,x,ms; mode=1)
    # layer 1
    conv1 = reslayerx1(w[1:3],x,ms; padding=3, stride=2, mode=mode)
    pool1 = pool(conv1; window=3, stride=2)

    # layer 2,3,4,5
    r2 = reslayerx5(w[4:33], pool1, ms; strides=[1,1,1,1], mode=mode)
    r3 = reslayerx5(w[34:108], r2, ms; mode=mode)
    r4 = reslayerx5(w[109:435], r3, ms; mode=mode)
    r5 = reslayerx5(w[436:465], r4, ms; mode=mode)

    # fully connected layer
    pool5  = pool(r5; stride=1, window=7, mode=2)
    fc1000 = w[466] * mat(pool5) .+ w[467]
end

# Batch Normalization Layer
# works both for convolutional and fully connected layers
# mode, 0=>train, 1=>test
function batchnorm(w, x, ms; mode=1, epsilon=1e-5)
    mu, sigma = nothing, nothing
    if mode == 0
        d = ndims(x) == 4 ? (1,2,4) : (2,)
        s = prod(size(x,d...))
        mu = sum(x,d) / s
        x0 = x .- mu
        x1 = x0 .* x0
        sigma = sqrt(epsilon + (sum(x1, d)) / s)
    elseif mode == 1
        mu = popfirst!(ms)
        sigma = popfirst!(ms)
    end

    # we need value in backpropagation
    push!(ms, value(mu), value(sigma))
    xhat = (x.-mu) ./ sigma
    return w[1] .* xhat .+ w[2]
end

function reslayerx0(w,x,ms; padding=0, stride=1, mode=1)
    b  = conv4(w[1],x; padding=padding, stride=stride)
    bx = batchnorm(w[2:3],b,ms; mode=mode)
end

function reslayerx1(w,x,ms; padding=0, stride=1, mode=1)
    relu.(reslayerx0(w,x,ms; padding=padding, stride=stride, mode=mode))
end

function reslayerx2(w,x,ms; pads=[0,1,0], strides=[1,1,1], mode=1)
    ba = reslayerx1(w[1:3],x,ms; padding=pads[1], stride=strides[1], mode=mode)
    bb = reslayerx1(w[4:6],ba,ms; padding=pads[2], stride=strides[2], mode=mode)
    bc = reslayerx0(w[7:9],bb,ms; padding=pads[3], stride=strides[3], mode=mode)
end

function reslayerx3(w,x,ms; pads=[0,0,1,0], strides=[2,2,1,1], mode=1) # 12
    a = reslayerx0(w[1:3],x,ms; stride=strides[1], padding=pads[1], mode=mode)
    b = reslayerx2(w[4:12],x,ms; strides=strides[2:4], pads=pads[2:4], mode=mode)
    relu.(a .+ b)
end

function reslayerx4(w,x,ms; pads=[0,1,0], strides=[1,1,1], mode=1)
    relu.(x .+ reslayerx2(w,x,ms; pads=pads, strides=strides, mode=mode))
end

function reslayerx5(w,x,ms; strides=[2,2,1,1], mode=1)
    x = reslayerx3(w[1:12],x,ms; strides=strides, mode=mode)
    for k = 13:9:length(w)
        x = reslayerx4(w[k:k+8],x,ms; mode=mode)
    end
    return x
end

function get_params(params, atype)
    len = length(params["value"])
    ws, ms = [], []
    for k = 1:len
        name = params["name"][k]
        value = convert(Array{Float32}, params["value"][k])

        if endswith(name, "moments")
            push!(ms, reshape(value[:,1], (1,1,size(value,1),1)))
            push!(ms, reshape(value[:,2], (1,1,size(value,1),1)))
        elseif startswith(name, "bn")
            push!(ws, reshape(value, (1,1,length(value),1)))
        elseif startswith(name, "fc") && endswith(name, "filter")
            push!(ws, transpose(reshape(value,(size(value,3),size(value,4)))))
        elseif startswith(name, "conv") && endswith(name, "bias")
            push!(ws, reshape(value, (1,1,length(value),1)))
        else
            push!(ws, value)
        end
    end
    map(wi->convert(atype, wi), ws),
    map(mi->convert(atype, mi), ms)
end

# This allows both non-interactive (shell command) and interactive calls like:
# $ julia vgg.jl cat.jpg
# julia> ResNet.main("cat.jpg")
PROGRAM_FILE=="resnet.jl" && main(ARGS)

end # module
