
binutil = {}
function binutil.minBits(n)
    local b = 0
    while n > (1<<b) do
        b = b + 1
    end
    return b
end
function binutil.limitBits(b,n)
    return n & (2^b-1)
end
local hTB = {
    ["0"]="0000",
    ["1"]="0001",
    ["2"]="0010",
    ["3"]="0011",
    ["4"]="0100",
    ["5"]="0101",
    ["6"]="0110",
    ["7"]="0111",
    ["8"]="1000",
    ["9"]="1001",
    ["a"]="1010",
    ["b"]="1011",
    ["c"]="1100",
    ["d"]="1101",
    ["e"]="1110",
    ["f"]="1111"
}
local hTBF = function(a) return hTB[a] end
function hexToBinary(s)
    return s:gsub('.', hTBF)
end

function bit(b)
    return b and 1 or 0
end
