# Copyright 2018 Erik Edin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Experimental

import Base: (|)

using Behavior.Gherkin: Given, When, Then, Scenario, ScenarioStep, AbstractScenario, Feature, FeatureHeader

struct GherkinSource
    lines::Vector{String}

    GherkinSource(source::String) = new(split(source, "\n"))
end

"""
    ParserInput

ParserInput encapsulates
- the Gherkin source
- the parser state (current line)
- the parser line operation (not implemented yet)
"""
struct ParserInput
    source::GherkinSource
    index::Int

    ParserInput(source::String) = new(GherkinSource(source), 1)
    ParserInput(input::ParserInput, index::Int) = new(input.source, index)
end

consume(input::ParserInput, n::Int) :: ParserInput = ParserInput(input, input.index + n)

function line(input::ParserInput) :: Tuple{Union{Nothing, String}, ParserInput}
    nextline = findfirst(x -> strip(x) != "" && !startswith(strip(x), "#"), input.source.lines[input.index:end])
    if nextline === nothing
        return nothing, input
    end
    strip(input.source.lines[input.index + nextline - 1]), consume(input, nextline)
end

"""
    Parser{T}

A Parser{T} is a callable that takes a ParserInput and produces
a ParseResult{T}. The parameter T is the type of what it parses.
"""
abstract type Parser{T} end

"""
    ParseResult{T}

A ParseResult{T} is the either successful or failed result of trying to parse
a value of T from the input.
"""
abstract type ParseResult{T} end

"""
    OKParseResult{T}(value::T)

OKParseResult{T} is a successful parse result.
"""
struct OKParseResult{T} <: ParseResult{T}
    value::T
    newinput::ParserInput
end

"""
    BadParseResult{T}

BadParseResult{T} is an abstract supertype for all failed parse results.
"""
abstract type BadParseResult{T} <: ParseResult{T} end

"""
    isparseok(::ParseResult{T})

isparseok returns true for successful parse results, and false for unsuccessful ones.
"""

isparseok(::OKParseResult{T}) where {T} = true
isparseok(::BadParseResult{T}) where {T} = false

struct BadExpectationParseResult{T} <: BadParseResult{T}
    expected::String
    actual::String
    newinput::ParserInput
end

struct BadUnexpectedParseResult{T} <: BadParseResult{T}
    unexpected::String
    newinput::ParserInput
end

struct BadInnerParseResult{S, T} <: BadParseResult{T}
    inner::BadParseResult{<:S}
    newinput::ParserInput
end

struct BadCardinalityParseResult{S, T} <: BadParseResult{T}
    inner::BadParseResult{S}
    atleast::Int
    actual::Int
    newinput::ParserInput
end

struct BadUnexpectedEOFParseResult{T} <: BadParseResult{T}
    newinput::ParserInput
end

struct BadExpectedEOFParseResult{T} <: BadParseResult{T}
    newinput::ParserInput
end

"""
    Line(expected::String)

Line is a parser that recognizes when a line is exactly an expected value.
It returns the expected value if it is found, or a bad parse result if not.
"""
struct Line <: Parser{String}
    expected::String
end

function (parser::Line)(input::ParserInput) :: ParseResult{String}
    s, newinput = line(input)

    if s === nothing
        BadUnexpectedEOFParseResult{String}(input)
    elseif s == parser.expected
        OKParseResult{String}(parser.expected, newinput)
    else
        BadExpectationParseResult{String}(parser.expected, s, input)
    end
end

"""
    Optionally{T}

Optionally{T} parses a value of type T if the inner parser succeeds, or nothing
if the inner parser fails. It always succeeds.
"""
struct Optionally{T} <: Parser{Union{Nothing, T}}
    inner::Parser{T}
end

function (parser::Optionally{T})(input::ParserInput) :: ParseResult{Union{Nothing, T}} where {T}
    result = parser.inner(input)
    if isparseok(result)
        OKParseResult{Union{Nothing, T}}(result.value, result.newinput)
    else
        OKParseResult{Union{Nothing, T}}(nothing, input)
    end
end

"""
    Or{T}(::Parser{T}, ::Parser{T})

Or matches either of the provided parsers. It short-circuits.
"""
struct Or{T} <: Parser{T}
    a::Parser{<:T}
    b::Parser{<:T}
end

function (parser::Or{T})(input::ParserInput) :: ParseResult{<:T} where {T}
    result = parser.a(input)
    if isparseok(result)
        result
    else
        parser.b(input)
    end
end

(|)(a::Parser{T}, b::Parser{T}) where {T} = Or{T}(a, b)

"""
    Transformer{S, T}

Transforms a parser of type S to a parser of type T, using a transform function.
"""
struct Transformer{S, T} <: Parser{T}
    inner::Parser{S}
    transform::Function
end

function (parser::Transformer{S, T})(input::ParserInput) where {S, T}
    result = parser.inner(input)
    if isparseok(result)
        newvalue = parser.transform(result.value)
        OKParseResult{T}(newvalue, result.newinput)
    else
        BadInnerParseResult{S, T}(result, input)
    end
end

"""
    Sequence{T}

Combine parsers into a sequence, that matches all of them in order.
"""
struct Sequence{T} <: Parser{Vector{T}}
    inner::Vector{Parser{<:T}}

    Sequence{T}(parsers...) where {T} = new(collect(parsers))
end

function (parser::Sequence{T})(input::ParserInput) :: ParseResult{Vector{T}} where {T}
    values = Vector{T}()
    currentinput = input

    for p in parser.inner
        result = p(currentinput)
        if isparseok(result)
            push!(values, result.value)
            currentinput = result.newinput
        else
            return BadInnerParseResult{T, Vector{T}}(result, input)
        end
    end

    OKParseResult{Vector{T}}(values, currentinput)
end

"""
    Joined

Joins a sequence of strings together into one string.
"""
Joined(inner::Parser{Vector{String}}) = Transformer{Vector{String}, String}(inner, x -> join(x, "\n"))

"""
    Repeating{T}

Repeats the provided parser until it no longer recognizes the input.
"""
struct Repeating{T} <: Parser{Vector{T}}
    inner::Parser{T}
    atleast::Int

    Repeating{T}(inner::Parser{T}; atleast::Int = 0) where {T} = new(inner, atleast)
end

function (parser::Repeating{T})(input::ParserInput) :: ParseResult{Vector{T}} where {T}
    values = Vector{T}()
    currentinput = input

    while true
        result = parser.inner(currentinput)
        if !isparseok(result)
            cardinality = length(values)
            if cardinality < parser.atleast
                return BadCardinalityParseResult{T, Vector{T}}(result, parser.atleast, cardinality, input)
            end
            break
        end
        push!(values, result.value)
        currentinput = result.newinput
    end

    OKParseResult{Vector{T}}(values, currentinput)
end

"""
    LineIfNot

Consumes a line if it does not match a given parser.
"""
struct LineIfNot <: Parser{String}
    inner::Parser{String}
end

function (parser::LineIfNot)(input::ParserInput) :: ParseResult{String}
    result = parser.inner(input)
    if isparseok(result)
        BadUnexpectedParseResult{String}(result.value, input)
    else
        s, newinput = line(input)
        if s === nothing
            BadUnexpectedEOFParseResult{String}(input)
        else
            OKParseResult{String}(s, newinput)
        end
    end
end

"""
    StartsWith

Consumes a line if it starts with a given string.
"""
struct StartsWith <: Parser{String}
    prefix::String
end

function (parser::StartsWith)(input::ParserInput) :: ParseResult{String}
    s, newinput = line(input)
    if s === nothing
        BadUnexpectedEOFParseResult{String}(input)
    elseif startswith(s, parser.prefix)
        OKParseResult{String}(s, newinput)
    else
        BadExpectationParseResult{String}(parser.prefix, s, input)
    end
end

struct EOFParser <: Parser{Nothing} end

function (parser::EOFParser)(input::ParserInput) :: ParseResult{Nothing}
    s, newinput = line(input)
    if s === nothing
        OKParseResult{Nothing}(nothing, newinput)
    else
        BadExpectedEOFParseResult{Nothing}(input)
    end
end

##
## Gherkin-specific parser
##

takeelement(i::Int) = xs -> xs[i]

"""
    BlockText

Parses a Gherkin block text.
"""
BlockText() = Transformer{Vector{String}, String}(
    Sequence{String}(
        Line("\"\"\""),
        Joined(Repeating{String}(LineIfNot(Line("\"\"\"")))),
        Line("\"\"\""),
    ),
    takeelement(2)
)

struct Keyword
    keyword::String
    rest::String
end

"""
    KeywordParser

Recognizes a keyword, and any following text on the same line.
"""
KeywordParser(word::String) = Transformer{String, Keyword}(
    StartsWith(word),
    s -> begin
        Keyword(word, strip(replace(s, word => "", count=1)))
    end
)

const MaybeBlockText = Union{Nothing, String}
const StepPieces = Union{Keyword, MaybeBlockText}

function StepParser(steptype::Type{T}, keyword::String) :: Parser{T} where {T}
    Transformer{Vector{StepPieces}, T}(
        Sequence{StepPieces}(KeywordParser(keyword), Optionally(BlockText())),
        sequence -> begin
            keyword = sequence[1]
            blocktext = if sequence[2] !== nothing
                sequence[2]
            else
                ""
            end
            steptype(keyword.rest, block_text=blocktext)
        end
    )
end

"""
    GivenParser

Consumes a Given step.
"""
GivenParser() = StepParser(Given, "Given ")
WhenParser() = StepParser(When, "When ")
ThenParser() = StepParser(Then, "Then ")

# TODO Find a way to express this as
#      GivenParser() | WhenParser() | ThenParser()
const AnyStepParser = Or{ScenarioStep}(
    Or{ScenarioStep}(GivenParser(), WhenParser()),
    ThenParser()
)
"""
    StepsParser

Parses zero or more steps.
"""
StepsParser() = Repeating{ScenarioStep}(AnyStepParser)

const ScenarioBits = Union{Keyword, Vector{ScenarioStep}}
"""
    ScenarioParser

Consumes a Scenario.
"""
ScenarioParser() = Transformer{Vector{ScenarioBits}, Scenario}(
    Sequence{ScenarioBits}(
        KeywordParser("Scenario:"),
        StepsParser()),
    sequence -> begin
        keyword = sequence[1]
        Scenario(keyword.rest, String[], Vector{ScenarioStep}(sequence[2]))
    end
)

struct Rule <: AbstractScenario
    description::String
    scenarios::Vector{AbstractScenario}
end

const ScenarioList = Vector{Scenario}
const RuleBits = Union{Keyword, ScenarioList}

"""
    RuleParser

Consumes a Rule and its child scenarios.
"""
RuleParser() = Transformer{Vector{RuleBits}, Rule}(
    Sequence{RuleBits}(KeywordParser("Rule:"), Repeating{Scenario}(ScenarioParser())),
    sequence -> begin
        keyword = sequence[1]
        scenarios = sequence[2]
        Rule(keyword.rest, scenarios)
    end
)

const FeatureBits = Union{Keyword, Vector{AbstractScenario}}
"""
    FeatureParser

Consumes a full feature file.
"""
const ScenarioOrRule = Or{AbstractScenario}(ScenarioParser(), RuleParser())
FeatureParser() = Transformer{Vector{FeatureBits}, Feature}(
    Sequence{FeatureBits}(KeywordParser("Feature:"), Repeating{AbstractScenario}(ScenarioOrRule)),
    sequence -> begin
        keyword = sequence[1]
        Feature(FeatureHeader(keyword.rest, [], []), sequence[2])
    end
)

const FeatureFileBits = Union{Feature, Nothing}
FeatureFileParser() = Transformer{Vector{FeatureFileBits}, Feature}(
    Sequence{FeatureFileBits}(FeatureParser(), EOFParser()),
    takeelement(1)
)

##
## Exports
##

export ParserInput, OKParseResult, BadParseResult, isparseok

# Basic combinators
export Line, Optionally, Or, Transformer, Sequence
export Joined, Repeating, LineIfNot, StartsWith, EOFParser

# Gherkin combinators
export BlockText, KeywordParser
export StepsParser, GivenParser, WhenParser, ThenParser
export ScenarioParser, RuleParser, FeatureParser, FeatureFileParser

# Data carrier types
export Keyword, Rule

end