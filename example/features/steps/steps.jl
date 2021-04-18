using Behavior: @given, @when, @then, @expect

@given("that the context variable :x has value 1") do context
    context[:x] = 1
end

@when("the context variable :x is compared with 1") do context
    v = context[:x] == 1
    context[:result] = v
end

@then("the comparison is true") do context
    @expect context[:result]
end

@when("this step fails") do context
    @expect 1 == 2
end

@then("this step is skipped") do context
    @assert false "This code is never executed, because the previous step failed."
end

@when("this step throws an exception, the result is \"Unknown exception\"") do context
    throw(ErrorException("This is an unknown exception"))
end

# This step is commented to show what happens when a step definition is not found.
#@given("a step that has no corresponding step definition in steps/spec.jl") do context
#
#end

@when("it is executed") do context
    @assert false "This step should be skipped, because the previous failed."
end

@then("it fails with error \"No matching step\"") do context
    @assert false "This step should be skipped, because a previous step failed."
end
