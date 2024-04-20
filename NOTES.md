# Rough Outline

1. `forge init` set up new project
2. install `v4-periphery` as forge lib

```
forge install https://github.com/Uniswap/v4-periphery
```

3. set up forge remappings

```
forge remappings > remappings.txt
```

4. Delete all the `Counter` related files

```
rm ./**/Counter*.sol
```

5. Create `PointsHook.sol`
